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
      @rows = build_rows(@agents)
      clamp_selection
    end

    # Flatten agents into selectable rows: active agents (each optionally followed
    # by its resource tree), then an "Archived (N)" header, then (when expanded)
    # up to @reveal archived agents and a "show more" row for the remainder.
    def build_rows(agents)
      active = agents.reject { |a| a[:archived] }
      archived = agents.select { |a| a[:archived] }.reverse
      rows = active.flat_map { |a| agent_and_tree(a) }
      return rows if archived.empty?

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
    def agent_and_tree(agent)
      rows = [{ type: :agent, agent: agent }]
      if @expanded.include?(agent[:name])
        (agent[:tickets] + agent[:prs]).each do |res|
          rows << { type: :resource, agent: agent, resource: res }
        end
      end
      rows
    end

    def handle(key)
      return handle_mouse(key) if key.is_a?(Hash)
      case key
      when "j", :down then move(1)
      when "k", :up   then move(-1)
      when "\r", "\n" then activate
      when "\t"       then toggle_tree_selected
      when :backtab   then toggle_tree_all
      when "a"        then archive_selected
      when "d"        then delete_selected
      when "n"        then @backend.new_agent
      when "b"        then bind_selected
      when "p"        then open_pr
      when "t"        then open_ticket
      when "v"        then open_editor_selected
      when "r"        then rename_selected
      when "z"        then @backend.open_plugins
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
      @sel = row_index
      row = @rows[row_index]
      if row[:type] == :agent
        id = clicked_resource_id(row[:agent], event[:x])
        id ? @backend.open_resource(id) : nil
      else
        activate # archive header / show-more
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
      (agent[:tickets] + agent[:prs]).flat_map { |res| res[:icons].map { res[:id] } }
    end

    def move(delta)
      return if @rows.empty?
      @sel = (@sel + delta).clamp(0, @rows.size - 1)
    end

    # Enter: toggle an agent's pane, open a resource (tree row), expand/collapse
    # the archive section, or reveal more archived agents.
    def activate
      row = @rows[@sel]
      return unless row
      case row[:type]
      when :agent          then @backend.toggle(row[:agent][:name])
      when :resource       then open_resource_row(row)
      when :archive_header then toggle_archive_disclosure
      when :more           then @reveal += REVEAL_STEP
      end
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
      row && %i[agent resource].include?(row[:type]) ? row[:agent][:name] : nil
    end

    def toggle_archive_disclosure
      @archive_expanded = !@archive_expanded
      @reveal = REVEAL_STEP
    end

    def archive_selected
      a = selected_agent
      @backend.archive(a[:name]) if a && !a[:archived]
    end

    # Bind/unbind the selected session to the main repo (needs a worktree; the
    # backend no-ops without one).
    def bind_selected
      a = selected_agent
      @backend.toggle_bind(a[:name]) if a
    end

    # Open the selected session's first associated pull request in the browser,
    # then return focus to its agent pane (if open) so the terminal is on the
    # agent when you come back.
    def open_pr
      a = selected_agent
      return unless a
      pr = a[:prs].first
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

    # Open the selected session's first associated ticket in the browser, then
    # return focus to its agent pane (if open). Same flow as open_pr.
    def open_ticket
      a = selected_agent
      return unless a
      ticket = a[:tickets].first
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
      (agent[:tickets] + agent[:prs]).flat_map { |res| res[:icons] }
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

    def clamp_selection
      @sel = @rows.empty? ? 0 : @sel.clamp(0, @rows.size - 1)
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
      else
        active.each { |a| $stdout.write(compact_row(a) + "\r\n") }
      end
    end

    # Minimized row: agent icon + ticket/PR icons + name (ticket ids, no
    # brackets) + a bound server icon, truncated to one line so nothing wraps.
    # No checkbox. The bind icon's width is reserved so the name doesn't push it
    # off the narrow drawer.
    def compact_row(agent)
      budget = cols - compact_icons_cols(agent) - bind_cols(agent) - 1
      name = truncate(agent[:display_plain].to_s, budget)
      body =
        if agent[:shown]
          "#{compact_icons(agent)}#{name}"
        else
          # Pane closed → name faint, but association icons keep their dimmed color.
          "#{compact_icons(agent, mode: :dim)}#{faint_seg(name)}"
        end
      body + bind_suffix(agent)
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
      $stdout.write("\r\n")
      if @rename_buf
        $stdout.write(center("rename: #{@rename_buf}▏") + "\r\n")
      elsif @confirm
        $stdout.write(center("delete #{@confirm}? (y/n)") + "\r\n")
      else
        $stdout.write(footer)
      end
      $stdout.write("\r\n  \e[38;5;196m! #{@last_error}\e[0m\r\n") if @last_error
    end

    def render_row(row, selected)
      # 2-column cursor (the Nerd selector glyph is wide): glyph+space when
      # selected, two spaces otherwise, so rows stay aligned.
      cursor = selected ? "#{Icons.selector} " : "  "
      content =
        case row[:type]
        when :agent
          a = row[:agent]
          # Archived agents render exactly like any other agent (state-colored
          # glyph, resource-colored association icons) — they're always closed, so
          # they take the not-shown path below like any other closed session. A
          # bound session just gets an aqua/red server icon appended. When the
          # tree is expanded, the inline association icons are dropped (assoc:
          # false) since they show as their own rows below.
          assoc = !@expanded.include?(a[:name])
          label = truncate(label_of(a), label_budget(a))
          # Inline annotations (e.g. a queued PR's ETA) sit after the icons, only
          # in the collapsed form (when expanded they'd show in the tree rows).
          ann = assoc ? row_annotations(a) : ""
          base =
            if !a[:shown]
              # Pane closed → checkbox/agent/name faint, but association icons keep
              # their dimmed color. Built per-segment (not one outer faint wrap) so
              # the colored glyphs' resets don't end the faint early.
              "  #{faint_seg(cursor)}#{row_icons(a, mode: :dim, assoc: assoc)}#{ann}#{faint_seg(label)}"
            else
              "  #{cursor}#{row_icons(a, assoc: assoc)}#{ann}#{label}"
            end
          base + bind_suffix(a)
        when :resource
          resource_row(row[:resource], cursor)
        when :archive_header
          caret = @archive_expanded ? "▾" : "▸"
          muted("  #{cursor}#{caret} Archived (#{row[:count]})")
        when :more
          muted("  #{cursor}  … show more (#{row[:remaining]})")
        end
      content = with_selection_bg(content) if selected
      "#{content}\r\n"
    end

    # A resource (ticket/PR) row under an expanded session: indented, its icons
    # in full color, then a truncated label (short id + title + any annotation
    # like a queued PR's ETA). Enter opens it.
    def resource_row(resource, cursor)
      glyphs = resource[:icons].map { |ic| styled_assoc(ic[:glyph], ic[:color], :normal) }.join(" ")
      text = resource[:annotation] ? "#{resource[:label]} #{resource[:annotation]}" : resource[:label].to_s
      budget = cols - 6 - (resource[:icons].size * 2) - 1
      "    #{cursor}#{glyphs} #{truncate(text, budget)}"
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
      (agent[:tickets] + agent[:prs]).map { |r| r[:annotation] }.compact
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
      cols - 4 - row_icons_cols(agent) - annotations_cols(agent) - bind_cols(agent) - 1
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

    # Key hints, filtered to what the hovered row actually supports: [↵] means
    # open on a resource row, show/hide on an agent; no [a] archive on an archived
    # item; [b] reads "unbind" when bound, and is hidden on an archived item or
    # one without a worktree; no [p] PR without a PR; [⇥] tree only when there are
    # resources. Wrapped to fit the drawer width and centered.
    def footer
      row = @rows[@sel]
      hints = ["[j/k] move"]
      case row && row[:type]
      when :resource
        hints << "[↵] open"
      when :agent
        a = row[:agent]
        hints << "[↵] show/hide" << "[r] rename"
        if a[:bound]
          hints << "[b] unbind"
        elsif !a[:archived] && a[:has_worktree]
          hints << "[b] bind"
        end
        hints << "[a] archive" unless a[:archived]
        hints << "[v] vim" if a[:shown]
        hints << "[p] PR" unless a[:prs].empty?
        hints << "[t] ticket" unless a[:tickets].empty?
        hints << "[⇥] tree" unless (a[:tickets] + a[:prs]).empty?
        hints << "[d] delete"
      else
        hints << "[↵] toggle"
      end
      hints << "[n] new" << "[z] plugins" << "[q] quit"
      wrap_hints(hints)
    end

    # Greedily pack hints into centered lines no wider than the drawer.
    def wrap_hints(hints)
      lines = []
      current = ""
      hints.each do |hint|
        candidate = current.empty? ? hint : "#{current}   #{hint}"
        if !current.empty? && candidate.length > cols
          lines << current
          current = hint
        else
          current = candidate
        end
      end
      lines << current unless current.empty?
      lines.map { |line| center(line) }.join("\r\n") + "\r\n"
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
      when "Z" then :backtab # Shift-Tab
      when /\A<(\d+);(\d+);(\d+)([Mm])\z/ # SGR mouse: <button;col;row;(M press|m release)
        { type: :mouse, button: $1.to_i, x: $2.to_i, y: $3.to_i, press: Regexp.last_match(4) == "M" }
      else "\e"
      end
    end
  end
end
