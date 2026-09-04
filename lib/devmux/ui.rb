require "io/console"
require "set"
require "devmux/tmux_session"
require "devmux/icons"

module Devmux
  # The devmux control-plane pane: the sidebar the multiplexer runs on launch.
  # From the user's perspective it *is* devmux. It manages agent panes without
  # the user ever touching the multiplexer directly.
  #
  # The sidebar is a drawer: narrow (minimized) while an agent is focused, wide
  # (expanded) while it's focused. It renders compact or full based on its own
  # pane width, and re-renders when the drawer resizes (SIGWINCH).
  #
  # It drives a backend (a TmuxBackend) exposing agents / new_agent / toggle /
  # archive / unarchive / delete / detach. Active agents render as a navigable
  # list; archived ones live behind a collapsible disclosure that reveals in
  # capped batches so a huge archive never floods the pane.
  class UI
    # Below this many columns, render the compact (minimized) view. Sits between
    # the collapsed drawer width and the expanded width.
    COMPACT_MAX_COLS = 20

    # How many archived agents the disclosure reveals per "show more" step.
    REVEAL_STEP = 10

    # Checkbox for whether the agent's pane is open (a separate concern from
    # state): filled square when shown, empty when hidden. Shared with the
    # plugins menu (see Icons) so the two use the same style.
    CHECK_SHOWN = Icons::CHECK_ON
    CHECK_HIDDEN = Icons::CHECK_OFF

    # How often (seconds) to wake and check whether the registry changed on disk
    # (e.g. an agent wrote its own context) while waiting for a keypress.
    POLL_INTERVAL = 0.2

    # Enable/disable SGR mouse reporting (button events, SGR-encoded coords). With
    # tmux `mouse on`, turning this on makes tmux forward clicks in the manager
    # pane to us so we can open a clicked resource icon; agent panes are
    # unaffected (they don't request mouse mode).
    MOUSE_ON = "\e[?1000h\e[?1006h".freeze
    MOUSE_OFF = "\e[?1000l\e[?1006l".freeze

    # Ask the terminal (via tmux, which has extended-keys on) to report modified
    # special keys — notably Shift+Enter — using xterm modifyOtherKeys level 2,
    # so we can tell Shift+Enter (expand/collapse all) from plain Enter (expand
    # one). tmux may relay these as CSI-u instead; decode_csi handles both forms.
    # Unmodified printable keys (j/k/space/…) are unaffected.
    EXTKEYS_ON = "\e[>4;2m".freeze
    EXTKEYS_OFF = "\e[>4m".freeze

    # Rows the centered hint block occupies at the top of the full view, so a
    # click's y maps to a list row (rows start on the line after it).
    HINT_HEIGHT = 4

    # 1-based terminal column where the association icons begin in a full row:
    # 2 (indent) + 2 (cursor) + 2 (checkbox) + 2 (agent glyph). Each icon is
    # glyph+space = 2 cells, so icon index = (col - ICON_START_COL) / 2.
    ICON_START_COL = 9

    def initialize(backend)
      @backend = backend
      @sel = 0
      @archive_expanded = false
      @reveal = REVEAL_STEP
      @confirm = nil
      @highlighted = :unset # sentinel so the first update_highlight always applies
      @focused = :unset     # sentinel so the first sync_drawer always applies
      @published_hover = nil # sentinel so the first publish_hover always applies
      @expanded = Set.new   # session names shown as a resource tree
      @rename_buf = nil     # non-nil while the rename prompt is active
      @hints_expanded = false # key hints hidden until toggled with "?"
      @collapsed_groups = Set.new # group ids whose members are hidden
      @flash = nil          # transient footer message (e.g. "copied!")
      @actions_menu = nil   # non-nil ({items:, sel:}) while the "m" menu is open
      refresh
    end

    def run
      # Re-render when the drawer resizes so the view switches compact<->full
      # without needing a keypress.
      Signal.trap("WINCH") { safe_render }
      # Keep the terminal in raw mode for the whole loop so single keypresses are
      # readable *and* IO.select can detect them per-char (cooked mode would
      # buffer to end-of-line, breaking the poll).
      IO.console.raw do
        $stdout.write(MOUSE_ON)
        $stdout.write(EXTKEYS_ON)
        $stdout.flush
        refresh
        render
        update_highlight
        @mtime = @backend.state_mtime
        loop do
          begin
            if input_ready?
              handle(read_key)
              refresh
              render
            elsif @backend.state_mtime != @mtime
              # State changed on disk with no keypress — e.g. an agent wrote its
              # own context, a hook updated its state, or an agent asked to show a
              # file. Act on any show requests, push names + state colors into the
              # pane title bars (the agent can't reach tmux from its sandbox), and
              # re-render the list.
              @backend.process_show_requests
              @backend.sync_panes
              refresh
              render
            end
            # Every tick (even idle polls), so a focus change made by any means
            # (Ctrl-Space, a mouse click, another keybind) is reflected promptly:
            # the drawer's size tracks focus (expanded when focused, collapsed
            # when not) and the hover highlight follows. One focus query, reused.
            focused = @backend.manager_focused?
            became_focused = focused && @focused != true
            sync_drawer(focused)
            select_on_expand if became_focused
            update_highlight(focused)
            publish_hover
            expire_flash
            @mtime = @backend.state_mtime
          rescue StandardError => e
            # Keep the manager alive on a transient error, but surface it (log
            # file + a line in the UI) rather than dying silently.
            TmuxSession.log_error("ui-loop", e)
            @last_error = "#{e.class}: #{e.message}"
            safe_render
            sleep 0.2
          end
        end
      end
    end

    # True if a keypress is waiting, else false after POLL_INTERVAL so the loop
    # can check for external state changes.
    def input_ready?
      !IO.select([$stdin], nil, nil, POLL_INTERVAL).nil?
    rescue StandardError
      true
    end

    private

    # Pull fresh state from the backend (main loop only — never the signal trap,
    # which must not shell out) and recompute the row layout.
    def refresh
      @agents = safe_agents
      @groups = safe_groups
      @rows = build_rows(@agents)
      clamp_selection
    end

    def safe_groups
      @backend.groups
    rescue StandardError
      @groups || []
    end

    # Flatten agents into rows, bucketed by group: first the unnamed group (no
    # header) at the top, then each named group — a blank spacer, a header, and
    # its members — in group order (named groups show even when empty, so a
    # session can be moved into one). Each active agent is optionally followed by
    # its resource tree. Then the "Archived (N)" disclosure, as before.
    def build_rows(agents)
      active = agents.reject { |a| a[:archived] }
      archived = agents.select { |a| a[:archived] }.reverse
      rows = []
      active.select { |a| a[:group].nil? }.each { |a| rows.concat(agent_and_tree(a)) }
      (@groups || []).each do |group|
        rows << { type: :spacer } unless rows.empty?
        rows << { type: :group_header, group: group }
        next if @collapsed_groups.include?(group[:id]) # collapsed: hide members
        active.select { |a| a[:group] == group[:id] }.each { |a| rows.concat(agent_and_tree(a)) }
      end
      return rows if archived.empty?

      rows << { type: :spacer } unless rows.empty?
      rows << { type: :archive_header, count: archived.size }
      if @archive_expanded
        revealed = archived.first(@reveal)
        revealed.each { |a| rows.concat(agent_and_tree(a)) }
        remaining = archived.size - revealed.size
        rows << { type: :more, remaining: remaining } if remaining.positive?
      end
      rows
    end

    # An agent row, plus a resource row per ticket/PR when its tree is expanded.
    # Each resource row records whether it's the last child, so render_row can
    # draw the right tree-branch connector (└─ for the last, ├─ otherwise).
    def agent_and_tree(agent)
      rows = [{ type: :agent, agent: agent }]
      if @expanded.include?(agent[:name])
        children = []
        # First child: the worktree's branch name (fetched lazily, only for the
        # expanded session). Enter on it copies the branch to the clipboard.
        branch = @backend.worktree_branch(agent[:name])
        children << { type: :branch, agent: agent, branch: branch } if branch && !branch.empty?
        resource_list(agent).each { |res| children << { type: :resource, agent: agent, resource: res } }
        children.each_with_index do |row, i|
          row[:last] = (i == children.size - 1)
          rows << row
        end
      end
      rows
    end

    def handle(key)
      return handle_mouse(key) if key.is_a?(Hash)
      # Ctrl-u / Ctrl-d jump the cursor between groups. Matched by ordinal (21/4)
      # so the source carries no literal control byte.
      if key.is_a?(String) && key.bytesize == 1
        return jump_group(-1) if key.ord == 21          # Ctrl-u
        return jump_group(1) if key.ord == 4            # Ctrl-d
        return delete_selected if [127, 8].include?(key.ord) # Backspace
      end
      case key
      when "j", :down    then move(1)
      when "k", :up      then move(-1)
      when "J"           then move_selected(1)
      when "K"           then move_selected(-1)
      when "\r", "\n"    then expand_collapse
      when :shift_enter  then toggle_tree_all
      when " "           then select_pane
      when "a"        then archive_selected
      when "d"        then show_diff_selected
      when "n"        then @backend.new_agent
      when "N"        then @backend.new_agent_pick
      when "p"        then open_pr
      when "t"        then open_ticket
      when "v"        then open_editor_selected
      when "c"        then open_console_selected(:worktree)
      when "C"        then open_console_selected(:main)
      when "m"        then open_actions_menu
      when "r"        then rename_selected
      when "z"        then @backend.open_settings
      when "?"        then @hints_expanded = !@hints_expanded
      when "q"        then @backend.detach
      end
    end

    # A left-click in the manager pane. Focus the drawer (the focus watcher then
    # expands it), then — in the full view — select the clicked row and, if the
    # click landed on a resource icon, open that resource in the browser.
    def handle_mouse(event)
      return unless event[:press] && event[:button].zero?
      @backend.focus_manager
      return if cols <= COMPACT_MAX_COLS
      row_index = event[:y] - HINT_HEIGHT - 1
      return unless (0...@rows.size).cover?(row_index)
      row = @rows[row_index]
      return unless selectable?(row) # ignore clicks on group headers / spacers
      @sel = row_index
      if row[:type] == :agent
        id = clicked_resource_id(row[:agent], event[:x])
        id ? @backend.open_resource(id) : nil
      else
        expand_collapse # archive header / show-more
      end
    end

    # The resource id whose icon sits at 1-based column `x` in a full row, or nil
    # (a click on the checkbox/agent glyph/name, or no icon there). Icons are laid
    # out 2 cells each from ICON_START_COL, one entry per glyph — and multiple
    # glyphs of one resource (PR + CI) all map back to that resource.
    def clicked_resource_id(agent, x)
      return nil unless Icons.nerd?
      return nil if x < ICON_START_COL
      resource_icon_ids(agent)[(x - ICON_START_COL) / 2]
    end

    # The resource id behind each association glyph, in render order (tickets then
    # PRs), so an icon index maps to the resource it belongs to.
    def resource_icon_ids(agent)
      resource_list(agent).flat_map { |res| res[:icons].map { res[:id] } }
    end

    # Row types the cursor can land on. Blank spacers are skipped over during
    # navigation; group headers are selectable (Enter collapses/expands them).
    SELECTABLE = %i[agent branch resource group_header archive_header more].freeze

    def selectable?(row)
      row && SELECTABLE.include?(row[:type])
    end

    # Move the cursor to the next selectable row in `delta`'s direction, skipping
    # headers/spacers. Stays put if there's none that way.
    def move(delta)
      return if @rows.empty?
      i = @sel
      loop do
        i += delta
        break if i.negative? || i >= @rows.size
        if selectable?(@rows[i])
          @sel = i
          return
        end
      end
    end

    # Shift-J/Shift-K: move the highlighted session one step through the grouped
    # order — swapping with its neighbour, or, at a group edge, crossing into the
    # adjacent group (which changes its group). Keeps the cursor on the session.
    def move_selected(delta)
      agent = selected_agent
      return unless agent
      @backend.move_agent(agent[:name], delta)
      refresh
      idx = @rows.index { |r| r[:type] == :agent && r[:agent][:name] == agent[:name] }
      @sel = idx if idx
    end

    # Ctrl-u / Ctrl-d: highlight the previous / next group. Anchors are the group
    # headers, plus the top of the unnamed group (its first session) so you can
    # jump back up into it. No-op past the first/last anchor.
    def jump_group(dir)
      anchors = group_anchors
      return if anchors.empty?
      cur = anchors.rindex { |i| i <= @sel }
      target = (cur.nil? ? (dir.positive? ? 0 : -1) : cur + dir)
      return if target.negative? || target >= anchors.size
      @sel = anchors[target]
    end

    # Row indices the group jump stops on: the first session of the unnamed group
    # (if any), then every group header.
    def group_anchors
      anchors = []
      first_header = @rows.index { |r| r[:type] == :group_header }
      scan_end = first_header || @rows.size
      unnamed = (0...scan_end).find { |i| @rows[i][:type] == :agent }
      anchors << unnamed if unnamed
      @rows.each_with_index { |r, i| anchors << i if r[:type] == :group_header }
      anchors
    end

    # Enter: expand/collapse the hovered session's resource tree, open a resource
    # (tree row), expand/collapse the archive section, or reveal more archived
    # agents. (Toggling a pane open/closed is now Space — see #select_pane.)
    def expand_collapse
      row = @rows[@sel]
      return unless row
      case row[:type]
      when :agent          then toggle_tree_selected
      when :branch         then copy_branch(row)
      when :resource       then open_resource_row(row)
      when :group_header   then toggle_group_collapse(row)
      when :archive_header then toggle_archive_disclosure
      when :more           then @reveal += REVEAL_STEP
      end
    end

    # Enter on a group header: hide/show its member sessions. Keeps the cursor on
    # the header.
    def toggle_group_collapse(row)
      id = row[:group][:id]
      @collapsed_groups.include?(id) ? @collapsed_groups.delete(id) : @collapsed_groups.add(id)
      refresh
      idx = @rows.index { |r| r[:type] == :group_header && r[:group][:id] == id }
      @sel = idx if idx
    end

    # Space: show/hide the hovered agent's pane (select/deselect it). Only agent
    # rows have a pane to toggle.
    def select_pane
      a = selected_agent
      @backend.toggle(a[:name]) if a
    end

    # Enter on the worktree branch row: copy the branch name to the clipboard and
    # flash a brief confirmation in the footer.
    def copy_branch(row)
      branch = row[:branch].to_s
      return if branch.empty?
      TmuxSession.copy_to_clipboard(branch) ? flash("copied!") : flash("copy failed")
    end

    # Show a brief message in the bottom section for ~1.2s (the run loop clears it).
    def flash(message)
      @flash = message
      @flash_until = Time.now + 1.2
      render
    end

    def flash_active?
      @flash && @flash_until && Time.now < @flash_until
    end

    # Clear an expired flash and repaint, so the "copied!" message disappears on
    # its own (checked each poll tick, ~0.2s granularity).
    def expire_flash
      return unless @flash && !flash_active?
      @flash = nil
      render
    end

    # Open a tree resource row's URL, then focus its agent pane (if open).
    def open_resource_row(row)
      @backend.open_resource(row[:resource][:id])
      @backend.focus_agent(row[:agent][:name])
    end

    # Tab: expand/collapse the resource tree for the hovered session (works from
    # either the agent row or one of its resource rows). Keeps the cursor on the
    # agent row afterward.
    def toggle_tree_selected
      name = selected_agent_name
      return unless name
      @expanded.include?(name) ? @expanded.delete(name) : @expanded.add(name)
      refresh
      idx = @rows.index { |r| r[:type] == :agent && r[:agent][:name] == name }
      @sel = idx if idx
    end

    # Shift-Tab: expand every session's tree, or collapse them all if any is open.
    def toggle_tree_all
      if @expanded.empty?
        @expanded.merge(@agents.map { |a| a[:name] })
      else
        @expanded.clear
      end
      refresh
    end

    # The session name for the selected row — the agent itself, or the parent of
    # a resource row.
    def selected_agent_name
      row = @rows[@sel]
      row && %i[agent branch resource].include?(row[:type]) ? row[:agent][:name] : nil
    end

    def toggle_archive_disclosure
      @archive_expanded = !@archive_expanded
      @reveal = REVEAL_STEP
    end

    def archive_selected
      a = selected_agent
      @backend.archive(a[:name]) if a && !a[:archived]
    end

    # Open the selected session's first associated pull request in the browser,
    # then return focus to its agent pane (if open) so the terminal is on the
    # agent when you come back.
    def open_pr
      a = selected_agent
      return unless a
      pr = a[:resources]["prs"].first
      return unless pr
      @backend.open_resource(pr[:id])
      @backend.focus_agent(a[:name])
    end

    # Open (or focus) a vim pane for the hovered session — the same split the
    # agent's `show` uses, triggered manually. Needs an open agent pane.
    def open_editor_selected
      name = selected_agent_name
      @backend.open_editor(name) if name
    end

    # Open (or focus) a raw console (shell) pane for the hovered session, split
    # above its agent like the vim/diff panes. `target` is :worktree (c) or :main
    # (C). Needs an open agent pane.
    def open_console_selected(target)
      name = selected_agent_name
      @backend.open_console(name, target: target) if name
    end

    # "m" — a modal menu of plugin command actions for the hovered session, drawn
    # in the footer. j/k move, Enter runs the highlighted action (start/stop its
    # background process), Esc closes. Blocks the main loop while open, like rename.
    def open_actions_menu
      name = selected_agent_name
      return unless name
      items = @backend.actions_for(name)
      return flash("no actions") if items.empty?
      @actions_menu = { items: items, sel: 0 }
      chosen = nil
      loop do
        render
        case (key = read_key_blocking)
        when "j", :down then @actions_menu[:sel] = (@actions_menu[:sel] + 1) % items.size
        when "k", :up   then @actions_menu[:sel] = (@actions_menu[:sel] - 1) % items.size
        when "\r", "\n" then chosen = items[@actions_menu[:sel]]; break
        when "\e", "q"  then break
        end
      end
      @actions_menu = nil
      render
      return unless chosen
      result = @backend.run_action(name, chosen[:plugin_id], chosen[:action_id])
      flash(action_result_message(result)) if result
    end

    def action_result_message(result)
      { started: "started", stopped: "stopped", needs_open: "open the session first",
        bound: "binding…", unbound: "unbound" }[result]
    end

    # Show a diff for the hovered row in a pane above its agent (through diffnav):
    # a highlighted PR resource diffs that PR (gh); an agent (or non-PR resource)
    # diffs its worktree branch vs the repo's main branch. The backend decides
    # from the resource id.
    def show_diff_selected
      row = @rows[@sel]
      return unless row
      case row[:type]
      when :resource then @backend.show_diff(row[:agent][:name], resource_id: row[:resource][:id])
      when :agent    then @backend.show_diff(row[:agent][:name])
      end
    end

    # Open the selected session's first associated ticket in the browser, then
    # return focus to its agent pane (if open). Same flow as open_pr.
    def open_ticket
      a = selected_agent
      return unless a
      ticket = a[:resources]["tickets"].first
      return unless ticket
      @backend.open_resource(ticket[:id])
      @backend.focus_agent(a[:name])
    end

    def delete_selected
      a = selected_agent
      return unless a
      @confirm = a[:name]
      render
      answer = read_key_blocking
      @confirm = nil
      @backend.delete(a[:name]) if answer == "y"
    end

    # Modal rename of the hovered session: a small line editor drawn where the
    # footer is. Enter commits, Esc cancels, Backspace deletes. Works from an
    # agent row or one of its resource rows (renames the parent session).
    def rename_selected
      name = selected_agent_name
      return unless name
      @rename_buf = +""
      loop do
        render
        key = read_key_blocking
        if ["\r", "\n"].include?(key)
          break
        elsif key == "\e"
          @rename_buf = nil
          break
        elsif ["", "\b"].include?(key)
          @rename_buf.chop!
        elsif key.is_a?(String) && key.bytesize == 1 && (0x20..0x7e).cover?(key.ord)
          @rename_buf << key
        end
      end
      new_name = @rename_buf
      @rename_buf = nil
      render
      @backend.rename(name, new_name.strip) if new_name && !new_name.strip.empty?
    end

    def selected_agent
      row = @rows[@sel]
      row && row[:type] == :agent ? row[:agent] : nil
    end

    # Keep the drawer's size aligned to focus: expand when the drawer is the
    # focused pane, collapse when it isn't — so a mouse click or any other means
    # of (de)focusing it resizes it, not just Ctrl-Space. Only acts on a change.
    def sync_drawer(focused)
      return if focused == @focused
      @focused = focused
      focused ? @backend.expand_drawer : @backend.collapse_drawer
    end

    # On expand, hover the entry for the agent that was focused (recorded by
    # toggle! in SELECT_OPTION), so the sidebar lands on where you just were.
    def select_on_expand
      name = @backend.take_select
      return unless name
      idx = @rows.index { |r| r[:type] == :agent && r[:agent][:name] == name }
      return unless idx
      @sel = idx
      render
    end

    # Publish the selected agent's name (or "") so a Ctrl-Space collapse focuses
    # its pane. Only pushes to tmux when the selection changed.
    def publish_hover
      name = selected_agent_name || ""
      return if name == @published_hover
      @published_hover = name
      @backend.publish_hover(name)
    end

    # Tell the backend which agent pane to highlight (blue border + title): the
    # hovered row's, but only in the expanded view and only if it has an open
    # pane. Kept out of #render (which the SIGWINCH trap also calls) since it
    # shells out to tmux; only re-issued when the target changes, to avoid churn.
    def update_highlight(focused = @backend.manager_focused?)
      name = highlighted_name(focused)
      return if name == @highlighted
      @highlighted = name
      @backend.highlight(name)
    end

    def highlighted_name(focused)
      # Only while the sidebar is both expanded and the focused pane — not when
      # collapsed, and not when an agent pane has focus (e.g. clicked into) with
      # the drawer still open.
      return nil if cols <= COMPACT_MAX_COLS
      return nil unless focused
      a = selected_agent
      a && a[:shown] ? a[:name] : nil
    end

    def label_of(agent)
      agent[:display] || agent[:name]
    end

    # SGR for the faint grey a not-shown row is drawn in (dim + grey 245).
    FAINT_SGR = "2;38;5;245".freeze

    # All icons for a row, lined up together to the left of the name: the
    # open/closed checkbox, the agent glyph (colored by state, matching the title
    # bar), then one ticket glyph per ticket and one PR glyph per PR. Each icon is
    # followed by a space so a 2-cell (non-Mono) Nerd glyph has room. Association
    # glyphs are Nerd Font only (Icons.ticket/pr are nil otherwise, and drop out).
    #
    # `mode` sets how everything is colored:
    #   :normal — shown row: agent glyph by state, association glyphs in full color.
    #   :dim    — not-shown row (incl. archived): checkbox + agent glyph faint grey,
    #             but association glyphs keep their color, just dimmed (so a closed
    #             pane still shows a merged PR as purple, only washed out).
    # `assoc: false` omits the inline ticket/PR icons — used when the session's
    # resource tree is expanded, since those show as their own rows below.
    def row_icons(agent, mode: :normal, assoc: true)
      checkbox = agent[:shown] ? CHECK_SHOWN : CHECK_HIDDEN
      head =
        if mode == :dim
          [faint_seg("#{checkbox} "), faint_seg("#{Icons.agent} ")]
        else
          ["#{checkbox} ", "#{colored_agent(agent)} "]
        end
      head.concat(assoc_glyphs(agent, mode)) if assoc && Icons.nerd?
      head.join
    end

    # Each resource's icons, laid out left to right (tickets then PRs), each glyph
    # with a trailing space. A resource is usually one glyph (the ticket/PR icon)
    # but a plugin can attach more — e.g. a PR carries a CI pass/fail glyph too.
    def assoc_glyphs(agent, mode)
      resource_icons(agent).map { |icon| "#{styled_assoc(icon[:glyph], icon[:color], mode)} " }
    end

    def resource_icons(agent)
      resource_list(agent).flat_map { |res| res[:icons] }
    end

    # All resource views for an agent (tickets, prs, and any plugin keys like
    # slack_threads) flattened in display order.
    def resource_list(agent)
      (agent[:resources] || {}).values.flatten
    end

    # A single association glyph, colored per mode: full color when :normal, the
    # same color dimmed when :dim (falling back to faint grey if the resource has
    # no color), and uncolored when :plain.
    def styled_assoc(glyph, color, mode)
      case mode
      when :normal then color ? "\e[#{color}m#{glyph}\e[0m" : glyph.to_s
      when :dim    then "\e[#{color ? "2;#{color}" : FAINT_SGR}m#{glyph}\e[0m"
      else glyph.to_s
      end
    end

    # Wrap a whole line in a muted grey (used for the archive section). The line
    # must contain no inner color resets, so render its icons plain (:plain).
    def muted(str)
      "\e[38;5;244m#{str}\e[0m"
    end

    # A faint grey segment. Used to build a not-shown row piece by piece (rather
    # than one outer wrap) so the dim-but-colored association glyphs in the middle
    # keep their color — an inner `\e[0m` would otherwise end a single outer wrap.
    def faint_seg(str)
      "\e[#{FAINT_SGR}m#{str}\e[0m"
    end

    # The agent glyph colored by state: orange while busy (active), grey when
    # idle (needs_input), faint when hidden (not running).
    def colored_agent(agent)
      sgr =
        if !agent[:shown] then "2;38;5;245"     # hidden — faint
        elsif agent[:state] == "busy" then "38;5;208" # active — orange
        else "38;5;250"                           # idle — grey
        end
      "\e[#{sgr}m#{Icons.agent}\e[0m"
    end

    # Keep the cursor in range AND on a selectable row (never on a group header
    # or spacer): snap to the nearest selectable row below, then above.
    def clamp_selection
      if @rows.empty?
        @sel = 0
        return
      end
      @sel = @sel.clamp(0, @rows.size - 1)
      return if selectable?(@rows[@sel])
      below = (@sel...@rows.size).find { |i| selectable?(@rows[i]) }
      above = @sel.downto(0).find { |i| selectable?(@rows[i]) }
      @sel = below || above || 0
    end

    def safe_agents
      @backend.agents
    rescue StandardError
      @agents || []
    end

    def cols
      IO.console.winsize[1]
    rescue StandardError
      (ENV["COLUMNS"] || 80).to_i
    end

    # Pane height in rows, used to pin the hint section to the bottom.
    def rows
      IO.console.winsize[0]
    rescue StandardError
      (ENV["LINES"] || 24).to_i
    end

    def safe_render
      render
    rescue StandardError
      nil
    end

    # Clear with an ANSI escape (home + clear screen + clear scrollback) rather
    # than `system("clear")`: this can be called from the SIGWINCH trap, and
    # forking a subprocess inside a signal handler is unsafe — it silently fails
    # to redraw, which is why the drawer only refreshed on a keypress.
    def clear
      $stdout.write("\e[H\e[2J\e[3J")
    end

    def render
      if cols <= COMPACT_MAX_COLS
        render_compact
      else
        render_full
      end
      $stdout.flush
    end

    # The centered "ctrl+space / to <action>" hint. render_compact and
    # render_full both emit it with the same height, so the session list stays at
    # the same row whether the drawer is minimized or open (it doesn't jump).
    def hint(action)
      center("ctrl+space") + "\r\n" + center("to #{action}") + "\r\n\r\n\r\n"
    end

    def center(str)
      pad = [(cols - str.length) / 2, 0].max
      (" " * pad) + str
    end

    def render_compact
      clear
      $stdout.write(hint("expand"))
      active = @agents.reject { |a| a[:archived] }
      if active.empty?
        $stdout.write("(none)\r\n")
        return
      end
      written = compact_group(nil, active, false)
      (@groups || []).each { |group| written = compact_group(group, active, written) }
    end

    # Render one group's compact rows (a truncated title line for a named group,
    # then its members). Empty named groups are omitted in the narrow view.
    # Returns whether anything has been written, so a blank spacer only goes
    # between non-empty sections.
    def compact_group(group, active, written)
      members = active.select { |a| a[:group] == (group && group[:id]) }
      return written if members.empty?
      if group
        $stdout.write("\r\n") if written
        $stdout.write(truncate(group[:name].to_s, cols) + "\r\n")
      end
      members.each { |a| $stdout.write(compact_row(a) + "\r\n") }
      true
    end

    # Minimized row: agent icon + ticket/PR icons + name (ticket ids, no
    # brackets) + a bound server icon, truncated to one line so nothing wraps.
    # No checkbox. The bind icon's width is reserved so the name doesn't push it
    # off the narrow drawer.
    def compact_row(agent)
      budget = cols - compact_icons_cols(agent) - bind_cols(agent) - bg_cols(agent) - 1
      name = truncate(agent[:display_plain].to_s, budget)
      body =
        if agent[:shown]
          "#{compact_icons(agent)}#{name}"
        else
          # Pane closed → name faint, but association icons keep their dimmed color.
          "#{compact_icons(agent, mode: :dim)}#{faint_seg(name)}"
        end
      body + bind_suffix(agent) + bg_suffix(agent)
    end

    # Agent glyph + one ticket/PR glyph per association, each with a trailing
    # space (2 cells for wide Nerd glyphs). See row_icons for `mode`.
    def compact_icons(agent, mode: :normal)
      head =
        case mode
        when :normal then "#{colored_agent(agent)} "
        when :dim    then faint_seg("#{Icons.agent} ")
        else "#{Icons.agent} "
        end
      parts = [head]
      parts.concat(assoc_glyphs(agent, mode)) if Icons.nerd?
      parts.join
    end

    def compact_icons_cols(agent)
      count = 1
      count += resource_icons(agent).size if Icons.nerd?
      count * 2
    end

    def truncate(str, width)
      return "" if width <= 0
      str.length <= width ? str : "#{str[0, width - 1]}…"
    end

    def render_full
      clear
      $stdout.write(hint("collapse"))
      if @rows.empty?
        $stdout.write("  (no agents)\r\n")
      else
        @rows.each_with_index { |row, i| $stdout.write(render_row(row, i == @sel)) }
      end
      draw_bottom
    end

    # The bottom section, pinned to the last rows of the pane via absolute cursor
    # positioning (so it reads as a footer regardless of how long the list is): a
    # modal prompt (rename/confirm) when one is active, otherwise the key-hints
    # section (a single "[?] help" line collapsed, the full vertical list on a gray
    # background when expanded). Any error is appended as the very last line.
    def draw_bottom
      block =
        if @actions_menu
          actions_menu_block
        elsif flash_active?
          ["\e[1;38;5;40m#{center(@flash)}\e[0m"] # brief confirmation, e.g. "copied!"
        elsif @rename_buf
          [center("rename: #{@rename_buf}▏")]
        elsif @confirm
          [center("delete #{@confirm}? (y/n)")]
        else
          hint_block
        end
      block += ["  \e[38;5;196m! #{@last_error}\e[0m"] if @last_error
      return if block.empty?
      start = [rows - block.size + 1, 1].max
      $stdout.write("\e[#{start};1H")
      block.each_with_index do |line, i|
        $stdout.write(line)
        $stdout.write("\r\n") unless i == block.size - 1
      end
    end

    # The actions-menu block (gray footer panel): a title, one line per action with
    # a ❯ cursor on the highlighted one, and the keybind hints.
    def actions_menu_block
      m = @actions_menu
      lines = [hint_bg_line("  actions")]
      m[:items].each_with_index do |item, i|
        cursor = i == m[:sel] ? "❯ " : "  "
        lines << hint_bg_line("  #{cursor}#{item[:label]}")
      end
      lines << hint_bg_line("  [j/k] move   [↵] select   [esc] close")
    end

    # The key-hints block: one dim "[?] help" line when collapsed, or the full
    # list — one hint per line on a gray background — when expanded.
    def hint_block
      return ["\e[2;38;5;245m  [?] help\e[0m"] unless @hints_expanded
      hint_items.map { |item| hint_bg_line("  #{item}") }
    end

    # A hint line filling the drawer width with a gray background, so the expanded
    # section reads as a distinct panel. `text` must carry no inner color resets.
    HINT_BG = "48;5;236".freeze
    def hint_bg_line(text)
      pad = [cols - text.length, 0].max
      "\e[#{HINT_BG}m#{text}#{' ' * pad}\e[0m"
    end

    def render_row(row, selected)
      return "\r\n" if row[:type] == :spacer
      content =
        case row[:type]
        when :group_header
          # A named group's title (emoji allowed) in aqua, led by a progressive-
          # disclosure arrow (▾ open / ▸ collapsed). Sits flush in the first column
          # (sessions are indented) to set groups apart, and dims when collapsed.
          # Unlike a session's resource tree, group members get no tree connectors.
          g = row[:group]
          collapsed = @collapsed_groups.include?(g[:id])
          arrow = collapsed ? "▸" : "▾"
          sgr = collapsed ? "2;38;5;39" : "1;38;5;39" # dim vs bold aqua
          "\e[#{sgr}m#{arrow} #{truncate(g[:name].to_s, cols - 3)}\e[0m"
        when :agent
          a = row[:agent]
          # Archived agents render exactly like any other agent (state-colored
          # glyph, resource-colored association icons) — they're always closed, so
          # they take the not-shown path below like any other closed session. A
          # bound session just gets an aqua/red server icon appended. When the
          # tree is expanded, the inline association icons are dropped (assoc:
          # false) since they show as their own rows below. A progressive-
          # disclosure chevron leads the row (▸/▾, blank when no resources).
          assoc = !@expanded.include?(a[:name])
          chev = chevron(a)
          label = truncate(label_of(a), label_budget(a))
          # Inline annotations (e.g. a queued PR's ETA) sit after the icons, only
          # in the collapsed form (when expanded they'd show in the tree rows).
          ann = assoc ? row_annotations(a) : ""
          base =
            if !a[:shown]
              # Pane closed → chevron/checkbox/agent/name faint, but association
              # icons keep their dimmed color. Built per-segment (not one outer
              # faint wrap) so the colored glyphs' resets don't end the faint early.
              "  #{faint_seg(chev)}#{row_icons(a, mode: :dim, assoc: assoc)}#{ann}#{faint_seg(label)}"
            else
              "  #{chev}#{row_icons(a, assoc: assoc)}#{ann}#{label}"
            end
          base + bind_suffix(a) + bg_suffix(a)
        when :branch
          branch_row(row)
        when :resource
          resource_row(row)
        when :archive_header
          # Also flush in the first column, like the group headers it sits among.
          caret = @archive_expanded ? "▾" : "▸"
          muted("#{caret} Archived (#{row[:count]})")
        when :more
          muted("     … show more (#{row[:remaining]})")
        end
      content = with_selection_bg(content) if selected
      "#{content}\r\n"
    end

    # Progressive-disclosure chevron for a session, in a fixed 2-cell slot so
    # rows stay aligned: ▾ when its resource tree is expanded, ▸ when collapsed
    # with resources to reveal, blank when it has none. Same glyphs as the
    # Archived disclosure's caret.
    def chevron(agent)
      # Expandable when it has resources OR a worktree (whose branch is the tree's
      # first row), so a worktree-only session still shows the disclosure arrow.
      return "  " if resource_list(agent).empty? && !agent[:has_worktree]
      @expanded.include?(agent[:name]) ? "▾ " : "▸ "
    end

    # A resource (ticket/PR) row under an expanded session: a tree-branch
    # connector (└─ for the last child, ├─ otherwise) descending from the
    # parent's chevron, its icons in full color, then a truncated label (short id
    # + title + any annotation like a queued PR's ETA). Enter opens it.
    # The worktree branch row (first child of an expanded session): a tree
    # connector, a branch glyph, and the branch name — all in normal gray. Enter
    # copies the branch name.
    def branch_row(row)
      connector = row[:last] ? "└─" : "├─"
      icon = Icons.nerd? ? "\u{f126} " : ""
      budget = cols - 5 - (Icons.nerd? ? 2 : 0) - 1
      "  \e[38;5;240m#{connector}\e[0m \e[38;5;245m#{icon}#{truncate(row[:branch].to_s, budget)}\e[0m"
    end

    def resource_row(row)
      resource = row[:resource]
      branch = row[:last] ? "└─" : "├─"
      glyphs = resource[:icons].map { |ic| styled_assoc(ic[:glyph], ic[:color], :normal) }.join(" ")
      # Annotation (e.g. a queued PR's ETA) sits right after the icons, before the
      # label — not appended after it, where truncating a long title would clip it.
      annotation = resource[:annotation].to_s
      ann = annotation.empty? ? "" : "\e[38;5;130m#{annotation}\e[0m "
      ann_cols = annotation.empty? ? 0 : annotation.length + 1
      budget = cols - 5 - (resource[:icons].size * 2) - ann_cols - 1
      "  \e[38;5;240m#{branch}\e[0m #{glyphs} #{ann}#{truncate(resource[:label].to_s, budget)}"
    end

    # Inline annotations for a row (e.g. queued PRs' ETAs), each in brown with a
    # trailing space, placed after the icon block. Nerd Font only (tied to the
    # icons). "" when none.
    def row_annotations(agent)
      return "" unless Icons.nerd?
      resource_annotations(agent).map { |a| "\e[38;5;130m#{a}\e[0m " }.join
    end

    def annotations_cols(agent)
      return 0 unless Icons.nerd?
      resource_annotations(agent).sum { |a| a.length + 1 }
    end

    def resource_annotations(agent)
      resource_list(agent).map { |r| r[:annotation] }.compact
    end

    # Wrap the selected row in a white background so the current item stands out
    # (on top of the arrow cursor). The row already contains inner `\e[0m` resets
    # (colored icons, faint text); each is followed by a re-assert of the
    # selection style so the background carries across the whole line, and a dark
    # default fg keeps plain text readable on white.
    SELECTION_SGR = "48;5;231;38;5;232".freeze
    def with_selection_bg(content)
      reassert = "\e[0m\e[#{SELECTION_SGR}m"
      "\e[#{SELECTION_SGR}m#{content.gsub("\e[0m", reassert)}\e[0m"
    end

    # How many columns the label may use in the full view before truncation:
    # the drawer width minus the fixed prefix (indent + cursor + icons), the
    # bound icon, and a right margin.
    def label_budget(agent)
      cols - 4 - row_icons_cols(agent) - annotations_cols(agent) - bind_cols(agent) - bg_cols(agent) - 1
    end

    # Terminal columns the leading icons occupy: checkbox + agent glyph (2 cells
    # each), plus 2 per association glyph when a Nerd Font is present.
    def row_icons_cols(agent)
      count = 2
      count += resource_icons(agent).size if Icons.nerd?
      count * 2
    end

    # A trailing server icon for a bound session — aqua when ok, red when broken —
    # or "" when unbound / no Nerd Font. Appended to sidebar rows (full and
    # compact) so a bind reads at a glance without recoloring the whole row.
    def bind_suffix(agent)
      return "" unless agent[:bound]
      glyph, color =
        case agent[:bind_status]
        when "broken"  then [Icons.server_broken, "38;5;160"]  # red
        when "dirty"   then [Icons.server_dirty, "38;5;220"]   # yellow
        when "binding" then [Icons.server_binding, "38;5;245"] # grey (in progress)
        else [Icons.server, "38;5;44"]                          # aqua
        end
      return "" unless glyph
      " \e[#{color}m#{glyph}\e[0m"
    end

    # Display columns bind_suffix occupies (server glyph + leading space).
    def bind_cols(agent)
      agent[:bound] && Icons.nerd? ? 2 : 0
    end

    # A trailing indicator per running plugin background process (the plugin's
    # glyph in the attention color), right-floated after the bind icon — the
    # enforced-visible "this is running" signal. "" when none / no Nerd Font.
    def bg_suffix(agent)
      inds = agent[:background] || []
      return "" if inds.empty? || !Icons.nerd?
      inds.map { |i| " \e[#{i[:color] || '38;5;214'}m#{i[:icon]}\e[0m" }.join
    end

    def bg_cols(agent)
      return 0 unless Icons.nerd?
      (agent[:background] || []).size * 2
    end

    # Key hints for the expanded section, one per line, filtered to what the
    # hovered row actually supports (as the old footer did) but with the reorder /
    # group-jump actions spelled out. [↵] is open on a resource row, tree/toggle
    # on an agent; [p]/[t] only with a PR/ticket; the group-jump line only when
    # groups exist. (Worktree bind now lives in the [m] actions menu.)
    def hint_items
      row = @rows[@sel]
      items = ["[j/k] move", "[J/K] reorder session"]
      items << "[^u/^d] jump between groups" unless (@groups || []).empty?
      case row && row[:type]
      when :branch
        items << "[↵] copy branch"
      when :resource
        items << "[↵] open" << "[d] diff"
      when :group_header
        items << (@collapsed_groups.include?(row[:group][:id]) ? "[↵] expand group" : "[↵] collapse group")
      when :agent
        a = row[:agent]
        items << "[space] show/hide" << "[r] rename"
        items << "[a] archive" unless a[:archived]
        items << "[v] vim" << "[c] console" << "[C] main console" if a[:shown]
        items << "[m] actions"
        items << "[p] PR" unless a[:resources]["prs"].empty?
        items << "[t] ticket" unless a[:resources]["tickets"].empty?
        items << "[↵] tree" unless resource_list(a).empty?
        items << "[d] diff" << "[⌫] delete"
      else
        items << "[↵] toggle"
      end
      items << "[n] new" << "[N] new in project" << "[z] settings"
      items << "[?] hide help" << "[q] quit"
      items
    end

    # Block until a keypress, then read it (used for the delete confirmation).
    def read_key_blocking
      IO.select([$stdin])
      read_key
    rescue StandardError
      ""
    end

    # Read a single keypress (no Enter), decoding arrow keys and SGR mouse events.
    # Assumes raw mode (see #run) and that input is ready, so an escape sequence
    # arrives whole; a lone ESC falls through. Ctrl-C is returned raw and simply
    # isn't a bound key, so it doesn't kill the manager. A mouse click returns a
    # hash { type: :mouse, button:, x:, y:, press: }.
    def read_key
      ch = $stdin.read_nonblock(1)
      return ch unless ch == "\e"
      return "\e" unless read_byte == "[" # only handle CSI sequences
      seq = +""
      loop do
        byte = read_byte
        break unless byte
        seq << byte
        break if byte =~ /[A-Za-z~]/ # CSI final byte
      end
      decode_csi(seq)
    rescue IO::WaitReadable, EOFError, StandardError
      ""
    end

    def read_byte
      $stdin.read_nonblock(1)
    rescue IO::WaitReadable, EOFError
      nil
    end

    def decode_csi(seq)
      case seq
      when "A" then :up
      when "B" then :down
      when "Z" then :backtab # Shift-Tab (unbound; kept for completeness)
      # Enter with modifiers. tmux relays extended keys as CSI-u (\e[13;<mod>u) or
      # xterm modifyOtherKeys (\e[27;<mod>;13~); mod 1 (or absent) is plain Enter,
      # anything higher means a modifier (Shift) is held → expand/collapse all.
      when "13u", "13;1u", "27;1;13~" then "\r"
      when /\A13;\d+u\z/, /\A27;\d+;13~\z/ then :shift_enter
      when /\A<(\d+);(\d+);(\d+)([Mm])\z/ # SGR mouse: <button;col;row;(M press|m release)
        { type: :mouse, button: $1.to_i, x: $2.to_i, y: $3.to_i, press: Regexp.last_match(4) == "M" }
      # Modified keys under xterm modifyOtherKeys level 2 (we enable it for
      # Shift+Enter): a Ctrl+letter arrives as CSI-u "<code>;<mod>u" or the
      # "27;<mod>;<code>~" form instead of the raw control byte. Map Ctrl-u /
      # Ctrl-d back to their bytes so #handle's ordinal check catches them (this is
      # why Ctrl-u/Ctrl-d were being swallowed in the manager pane).
      # Backspace can also arrive as CSI-u (\e[127u) under modifyOtherKeys; map it
      # back to the DEL byte so #handle's ordinal check deletes.
      when "127u", "127;1u", "8u", "8;1u" then [127].pack("C")
      when /\A(\d+);(\d+)u\z/ then extended_key($1.to_i, $2.to_i)
      when /\A27;(\d+);(\d+)~\z/ then extended_key($2.to_i, $1.to_i)
      else "\e"
      end
    end

    # Map a modifyOtherKeys code+modifier to a raw byte we handle, or "\e" if it's
    # not one we care about. The modifier is xterm-encoded (1 + bitmask; Ctrl bit
    # = 4), so Ctrl is held when (mod - 1) & 4 is set. Ctrl-u (code 117) and Ctrl-d
    # (code 100) become bytes 0x15 / 0x04.
    def extended_key(code, mod)
      ctrl = ((mod - 1) & 4) != 0
      return "\e" unless ctrl
      case code
      when 117 then [21].pack("C") # Ctrl-u
      when 100 then [4].pack("C")  # Ctrl-d
      else "\e"
      end
    end
  end
end
