require "fileutils"
require "shellwords"
require "digest"
require "json"
require "io/console"
require "devmux/tmux"
require "devmux/registry"
require "devmux/plugins"
require "devmux/plugin_host"
require "devmux/icons"

module Devmux
  # Three entry contexts share this module:
  #   - launch!  runs OUTSIDE tmux (a bare `devmux`): create-or-attach the session.
  #   - the manager UI runs INSIDE the manager pane and drives TmuxBackend.
  #   - toggle!  runs from the global Ctrl-Space keybind (a fresh process, no
  #     shared state) and resizes/focuses the drawer purely from queried state.
  module TmuxSession
    SESSION = Tmux::SESSION
    MANAGER_TITLE = "devmux-manager".freeze
    FOCUS_KEY = "C-Space".freeze
    # tmux session option recording the devmux source stamp the session was
    # created from, so a relaunch can detect an update.
    STAMP_OPTION = "@devmux_stamp".freeze
    # tmux session option recording the directory devmux was last launched from,
    # so new agents open there — not in devmux's own dir or a stale session's dir.
    LAUNCH_DIR_OPTION = "@devmux_launch_dir".freeze
    # Session options coupling the sidebar selection and pane focus across the
    # Ctrl-Space toggle (which runs in a separate process from the UI):
    #   HOVER_OPTION  — the UI publishes the currently-selected agent's name here,
    #                   so collapsing focuses that agent's pane.
    #   SELECT_OPTION — on expand, toggle! records the agent that was focused here,
    #                   so the UI can move its selection to that entry.
    HOVER_OPTION = "@devmux_hover".freeze
    SELECT_OPTION = "@devmux_select".freeze

    # Drawer widths in columns. Collapsed sits below UI::COMPACT_MAX_COLS so the
    # sidebar renders its compact view; expanded sits above it.
    COLLAPSED_WIDTH = 16
    EXPANDED_WIDTH = 44

    module_function

    def inside_session?
      Tmux.inside_session?
    end

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def log_path
      File.join(state_dir, "devmux.log")
    end

    # Plugin activity (poll cycles, what each plugin found/did) goes to its own
    # log so it's easy to tail while debugging a plugin, separate from the UI's
    # error log. `devmux plugins log` prints it.
    def plugin_log_path
      File.join(state_dir, "plugins.log")
    end

    def log_plugin(message)
      FileUtils.mkdir_p(state_dir)
      File.open(plugin_log_path, "a") { |f| f.puts "#{Time.now} #{message}" }
    rescue StandardError
      nil
    end

    # Open a URL in the user's browser. On macOS, first try to switch to an
    # existing Chrome tab already showing the URL (so clicking a PR icon twice
    # doesn't pile up duplicate tabs); only open a fresh tab if none matches.
    # Falls back to `open` / `xdg-open`. Fire-and-forget; failures are swallowed.
    def open_url(url)
      url = url.to_s
      return if url.empty?
      if RUBY_PLATFORM.include?("darwin")
        return if focus_chrome_tab(url)
        system("open", url, out: File::NULL, err: File::NULL)
      else
        system("xdg-open", url, out: File::NULL, err: File::NULL)
      end
    rescue StandardError
      nil
    end

    # Focus an existing Chrome tab whose URL starts with `url` (covers PR
    # sub-pages like /files), else open it in a new tab / window. Returns true if
    # Chrome handled it, false if Chrome isn't available (so we can fall back).
    # The URL is passed as an argv argument to avoid AppleScript string escaping.
    def focus_chrome_tab(url)
      system("osascript", "-e", CHROME_FOCUS_SCRIPT, url,
             out: File::NULL, err: File::NULL)
    rescue StandardError
      false
    end

    CHROME_FOCUS_SCRIPT = <<~'APPLESCRIPT'.freeze
      on run argv
        set target to item 1 of argv
        tell application "Google Chrome"
          repeat with w in windows
            set i to 0
            repeat with t in tabs of w
              set i to i + 1
              set u to URL of t
              if (u is target) or (u starts with (target & "/")) or (u starts with (target & "?")) or (u starts with (target & "#")) then
                set active tab index of w to i
                set index of w to 1
                activate
                return
              end if
            end repeat
          end repeat
          if (count of windows) is 0 then
            make new window
            set URL of active tab of front window to target
          else
            tell front window to make new tab with properties {URL:target}
          end if
          activate
        end tell
      end run
    APPLESCRIPT

    # The user-facing name: the context "name" if set, otherwise the slug.
    def display_name(record)
      name = (record["context"] || {})["name"]
      name && !name.to_s.empty? ? name : record["name"]
    end

    # The label shown in the title bar and sidebar: any ticket ids prefixed
    # before the name, e.g. "[MAT-123, MAT-523] Refactor auth". If the agent also
    # put a ticket id in the name (e.g. "MAT-123 dash tracking"), it's stripped
    # so it doesn't show twice.
    def display_label(record, brackets: true)
      # Only currently-valid ids count: an identifier whose scheme belongs to a
      # disabled plugin is ignored (left in the context, just not shown).
      tickets = Array((record["context"] || {})["tickets"]).select { |t| Providers.valid?(t) }
      shorts = tickets.map { |t| Providers.short(t) }
      name = display_name(record)
      # Strip both the full id and its short form, in case the agent put either
      # in the name too.
      name = strip_tickets(name, (tickets + shorts).uniq) unless tickets.empty?
      return name if shorts.empty?
      ids = brackets ? "[#{shorts.join(', ')}]" : shorts.join(' ')
      "#{ids} #{name}".strip
    end

    # The resource icons (ticket/PR/CI/…) for a pane title bar, as a tmux format
    # fragment — the same glyphs the sidebar draws, styled with tmux `#[fg=…]` so
    # they render in a pane-border-format via `#{E:@devmux_icons}`. Empty without
    # a Nerd Font (association glyphs are Nerd-only) or when there are no valid
    # resources. Pushed onto each shown pane's @devmux_icons option (like the
    # label/state), so it recolors as a plugin's polled state changes.
    def title_icons(record)
      return "" unless Icons.nerd?
      ctx = record["context"] || {}
      parts = []
      collect_title_icons(ctx["tickets"], Icons.ticket, parts)
      collect_title_icons(ctx["prs"], Icons.pr, parts)
      parts.empty? ? "" : "#{parts.join(' ')} "
    end

    def collect_title_icons(value, base_glyph, parts)
      Array(value).select { |id| Providers.valid?(id) }.each do |id|
        details = Plugins.resource_details(id)
        if base_glyph
          glyph = (details && details[:glyph]) || base_glyph
          parts << styled_title_icon(glyph, details && details[:color])
        end
        Array(details && details[:icons]).each { |i| parts << styled_title_icon(i[:glyph], i[:color]) }
        # Annotation (e.g. a queued PR's ETA) beside the resource's icons.
        parts << "#[fg=colour130]#{details[:annotation]}" if details && details[:annotation]
      end
    end

    def styled_title_icon(glyph, color)
      tmux = tmux_color(color)
      tmux ? "#[fg=#{tmux}]#{glyph}" : glyph.to_s
    end

    # Convert an ANSI 256-color SGR ("38;5;N", maybe dim-prefixed) to a tmux color
    # ("colourN"), or nil if it isn't one (leave the glyph the bar's own color).
    def tmux_color(sgr)
      m = sgr.to_s.match(/38;5;(\d+)/)
      m && "colour#{m[1]}"
    end

    # Remove the given ticket ids (and any brackets/separators they leave behind)
    # from a title, so a prefixed ticket isn't duplicated in the name.
    def strip_tickets(name, tickets)
      cleaned = name.dup
      tickets.each do |ticket|
        # Whole-token match only, so "MAT-2" doesn't clip "MAT-26".
        cleaned = cleaned.gsub(/(?<![\w-])#{Regexp.escape(ticket)}(?![\w-])/i, "")
      end
      cleaned = cleaned.gsub(/\[[\s,]*\]|\([\s,]*\)/, "") # drop now-empty brackets
      cleaned = cleaned.gsub(/\s+/, " ").strip
      cleaned.sub(/\A[\s:,\-–—]+/, "").sub(/[\s:,\-–—]+\z/, "").strip
    end

    # Append an error (with backtrace) to the log so failures are inspectable
    # rather than vanishing with a dead pane.
    def log_error(context, error)
      FileUtils.mkdir_p(state_dir)
      File.open(log_path, "a") do |f|
        f.puts "#{Time.now} [#{context}] #{error.class}: #{error.message}"
        Array(error.backtrace).first(20).each { |line| f.puts "  #{line}" }
      end
    rescue StandardError
      nil
    end

    # Bare `devmux` from a normal shell: attach to the live session if one
    # exists, otherwise create it fresh. tmux persists the session (and its agent
    # processes) across disconnects for free, so there is no serialization to
    # disable and no stale-resurrection problem.
    #
    # Config (keybinds, layout) only takes effect when the server is created, so
    # a plain reattach can't pick up code/config changes. If devmux's own source
    # has changed since the session started, offer to kill + restart instead of
    # reattaching blindly. (Preserving in-flight agent state across a restart is
    # future work.)
    def launch!(exe_path, status_bar: false)
      config = write_config(exe_path, status_bar: status_bar)
      tmux = Tmux.new
      if tmux.has_session?
        restart!(tmux, exe_path, config) if outdated?(tmux, exe_path) && confirm_restart?
      else
        create_session(tmux, exe_path, config)
      end
      # Record where devmux was launched from so new agents open here, even when
      # reattaching to a session first created in a different directory.
      tmux.set_option(LAUNCH_DIR_OPTION, Dir.pwd)
      attach
    end

    def restart!(tmux, exe_path, config)
      tmux.kill_session
      create_session(tmux, exe_path, config)
    end

    # True if the running session was created from a different devmux than the
    # one on disk now.
    def outdated?(tmux, exe_path)
      stored = tmux.get_option(STAMP_OPTION)
      current = repo_stamp(exe_path)
      return false if stored.nil? || stored.empty? || current.nil?
      stored != current
    end

    def confirm_restart?
      $stderr.print "devmux was updated since this session started. " \
                    "Restart it? Running agents will be killed. [y/N] "
      answer = $stdin.gets
      !answer.nil? && answer.strip.downcase.start_with?("y")
    rescue StandardError
      false
    end

    # A hash of devmux's own source (bin + lib) — what actually determines how a
    # running session behaves. Catches uncommitted edits too, and doesn't churn
    # on doc-only changes. Swap in `git rev-parse HEAD` here if you'd rather key
    # off commits.
    def repo_stamp(exe_path)
      root = File.expand_path("..", File.dirname(exe_path))
      files = Dir.glob(File.join(root, "{bin,lib}", "**", "*"))
                 .select { |f| File.file?(f) }.sort
      return nil if files.empty?
      digest = Digest::SHA1.new
      files.each do |f|
        digest.update(f.sub(root, ""))
        digest.update(File.read(f))
      end
      digest.hexdigest[0, 16]
    rescue StandardError
      nil
    end

    def write_config(exe_path, status_bar: false)
      dir = state_dir
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "tmux.conf")
      File.write(path, config_tmux(exe_path, status_bar: status_bar))
      path
    end

    # The manager pane runs `devmux ui`, which spawns agent-1 itself on a fresh
    # start (no agents present) — so there is no create-time race between seeding
    # the UI and creating the first agent. All of this happens headlessly, before
    # we attach a client (tmux resizes/splits/focuses with no client attached).
    def create_session(tmux, exe_path, config)
      cols, rows = terminal_size
      tmux.new_session(config: config, cwd: Dir.pwd,
                       command: "#{exe_path.shellescape} ui", cols: cols, rows: rows)
      manager = tmux.panes.first
      tmux.set_title(manager[:id], MANAGER_TITLE) if manager
      stamp = repo_stamp(exe_path)
      tmux.set_option(STAMP_OPTION, stamp) if stamp
    end

    # Run tmux as a child (not exec) so we regain control when the client
    # detaches and can erase tmux's one-line "[detached ...]" notice, keeping the
    # illusion that devmux is a standalone app. Ignore the terminal's close
    # signals so this process survives to do that; the tmux client still exits.
    def attach
      %w[HUP TERM].each { |sig| Signal.trap(sig, "IGNORE") }
      system("tmux", "-L", Tmux::SOCKET, "attach", "-t", SESSION)
      $stdout.write("\e[1A\e[2K\r")
      $stdout.flush
    rescue StandardError
      nil
    end

    def terminal_size
      rows, cols = IO.console.winsize
      cols = 200 if cols.nil? || cols.zero?
      rows = 50 if rows.nil? || rows.zero?
      [cols, rows]
    rescue StandardError
      [200, 50]
    end

    # Global Ctrl-Space handler, invoked as a standalone process by the keybind.
    # It reads the manager's current width to decide direction. The sidebar
    # selection and pane focus stay coupled via two session options (see
    # HOVER_OPTION / SELECT_OPTION):
    #   - Expanding records the agent that was focused (SELECT_OPTION) so the UI
    #     hovers its entry, then focuses the manager.
    #   - Collapsing focuses the pane of the currently-hovered entry (HOVER_OPTION),
    #     falling back to the last-active pane when it has none.
    def toggle!
      tmux = Tmux.new
      panes = tmux.panes
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return unless manager

      if manager[:width] <= (COLLAPSED_WIDTH + EXPANDED_WIDTH) / 2
        active = panes.find { |p| p[:active] }
        tmux.set_option(SELECT_OPTION, (active && active[:agent]) || "")
        set_layout(tmux, EXPANDED_WIDTH)
        tmux.focus(manager[:id])
      else
        hovered = tmux.get_option(HOVER_OPTION)
        pane = hovered.to_s.empty? ? nil : panes.find { |p| p[:agent] == hovered }
        set_layout(tmux, COLLAPSED_WIDTH)
        pane ? tmux.focus(pane[:id]) : tmux.focus_last
      end
    end

    # Give every agent pane an equal share of the width left over after the
    # manager: set each agent (bar the last, which absorbs the rounding
    # remainder) to `each` columns, left to right.
    def rebalance_agents(tmux)
      panes = tmux.panes
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return unless manager
      tmux.batch(agent_resize_commands(tmux, panes, manager[:width]))
    end

    # Resize the manager drawer to `manager_width` AND re-even the agents to the
    # width left over — all in ONE tmux invocation, so tmux reflows and redraws
    # once instead of flickering the agent panes through intermediate widths on
    # every expand/collapse.
    def set_layout(tmux, manager_width)
      panes = tmux.panes
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return unless manager
      commands = [["resize-pane", "-t", manager[:id], "-x", manager_width.to_s]]
      commands.concat(agent_resize_commands(tmux, panes, manager_width))
      tmux.batch(commands)
    end

    # The resize commands (arg arrays) that even out the agent columns for a given
    # manager width. Only real agent panes (@devmux_agent) count — a vim "show"
    # pane shares its agent's column, so resizing the agent resizes it too.
    def agent_resize_commands(tmux, panes, manager_width)
      agents = panes.select { |p| p[:agent] }
      return [] if agents.empty?
      count = agents.size
      avail = tmux.window_width - manager_width - count
      each = avail / count
      return [] if each < 1
      agents[0...-1].map { |a| ["resize-pane", "-t", a[:id], "-x", each.to_s] }
    end

    # Default agent program. Overridable per-launch via DEVMUX_AGENT (assumed
    # Claude-CLI-compatible for the session flags); a real per-session/per-user
    # default is future work.
    DEFAULT_AGENT = "claude".freeze

    def agent_program
      agent = ENV["DEVMUX_AGENT"]
      agent.nil? || agent.empty? ? DEFAULT_AGENT : agent
    end

    # Pick the right invocation for a session id. Claude only persists a session
    # (writing <uuid>.jsonl) after its first message, and the two flags are
    # mutually exclusive: `--resume` errors if the session doesn't exist, and
    # `--session-id` errors ("already in use") if it does. So we check for the
    # session file first — resume it if present, otherwise start it fresh. This
    # is why re-showing an agent you never typed into starts clean instead of
    # erroring.
    def agent_command(uuid, exe: nil)
      if session_exists?(uuid)
        resume_agent_command(uuid, exe: exe)
      else
        new_agent_command(uuid, exe: exe)
      end
    end

    # Start a fresh agent under a chosen session id so it can be resumed later.
    def new_agent_command(uuid, exe: nil)
      claude_command("--session-id #{uuid}", exe: exe, uuid: uuid)
    end

    # Resume a previously-created agent by its session id.
    def resume_agent_command(uuid, exe: nil)
      claude_command("--resume #{uuid}", exe: exe, uuid: uuid)
    end

    def claude_command(session_flag, exe:, uuid:)
      with_shell_fallback(
        "#{agent_program} #{add_dir_flag} #{system_prompt_flag(exe, uuid)} " \
        "--settings #{hooks_settings} #{session_flag}"
      )
    end

    # A system-prompt nudge (stronger than CLAUDE.md, always present) telling the
    # agent to keep its devmux context current. It embeds the *literal* devmux
    # path and session id — not shell variables — so the command the agent runs
    # is a plain, traceable invocation that Claude's worktree-isolation guard
    # accepts (variables like $DEVMUX_SESSION make it "too complex to verify").
    # Single-quoted for the shell; the text contains no single quotes.
    def system_prompt_flag(exe, uuid)
      bin = exe || "devmux"
      text =
        "You are running inside devmux, which shows a sidebar of agent sessions. " \
        "FIRST, run #{bin} context read #{uuid} to see this session's context keys and what " \
        "each one means, and immediately fill in or correct anything relevant to your task. " \
        "Then keep the context up to date, running these exact commands with literal values " \
        "(do NOT use shell variables, so they work in a worktree-isolated session): " \
        "set a short title (max 25 chars) with #{bin} context write #{uuid} name \"<title>\"; " \
        "record the ticket(s) you are working on as scheme-prefixed ids " \
        "(linear:MAT-123, or github:owner/repo/issue/123) with " \
        "#{bin} context write #{uuid} tickets linear:MAT-123 ...; " \
        "the moment you create a git worktree for this work, record its absolute path with " \
        "#{bin} context write #{uuid} worktree <path>; " \
        "the moment you create or discover a PR (for example right after gh pr create), record it " \
        "as github:owner/repo/pull/<number> with #{bin} context write #{uuid} prs " \
        "github:owner/repo/pull/1514 ... " \
        "Re-run the relevant command whenever any of these change. " \
        "To show the user a file in an editor beside you, run " \
        "#{bin} show <file> <start>-<end> (or a single line, or no lines) — it opens " \
        "the file in a vim pane above you, reusing that pane for later shows."
      "--append-system-prompt #{text.shellescape}"
    end

    # Add devmux's state dir to Claude's allowed directories so the agent's
    # sandboxed shell can actually write its own context (`devmux context write`)
    # — otherwise the write is denied and the registry never updates.
    def add_dir_flag
      "--add-dir #{state_dir.shellescape}"
    end

    # Inject hooks that report the agent's state into its own devmux context:
    # working on submit, needs_input on a permission/idle notification, idle when
    # a turn ends. Hooks run OUTSIDE Claude's Bash sandbox, so they can write the
    # state dir; they address the session via $DEVMUX_SESSION / $DEVMUX_BIN, which
    # devmux exports into the pane. Passed as one single-quoted shell arg (the
    # JSON contains no single quotes).
    def hooks_settings
      config = { "hooks" => {
        "UserPromptSubmit" => [{ "hooks" => [
          { "type" => "command", "command" => hook_cmd("busy") },
          # Auto-fill name (from the prompt) + worktree (from cwd).
          { "type" => "command", "command" => autosync_cmd },
        ] }],
        "Notification" => [{ "matcher" => "permission_prompt|idle_prompt",
                             "hooks" => [{ "type" => "command", "command" => hook_cmd("needs_input") }] }],
        "Stop" => [{ "hooks" => [
          { "type" => "command", "command" => hook_cmd("needs_input") },
          # Also autosync at turn end, to catch a worktree created mid-turn.
          { "type" => "command", "command" => autosync_cmd },
        ] }],
      } }
      JSON.generate(config).shellescape
    end

    def hook_cmd(state)
      %{"$DEVMUX_BIN" context write "$DEVMUX_SESSION" agent_state #{state} >/dev/null 2>&1 || true}
    end

    def autosync_cmd
      %{"$DEVMUX_BIN" context autosync "$DEVMUX_SESSION" >/dev/null 2>&1 || true}
    end

    # Has Claude persisted a conversation for this session id? Sessions live at
    # ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl; we glob across project dirs
    # (a UUID is globally unique) so we don't depend on Claude's exact cwd
    # encoding.
    def session_exists?(uuid)
      pattern = File.join(Dir.home, ".claude", "projects", "*", "#{uuid}.jsonl")
      !Dir.glob(pattern).empty?
    rescue StandardError
      false
    end

    # Drop to a shell when the agent exits (or if it isn't installed / the
    # session can't be resumed) so the pane persists rather than vanishing.
    def with_shell_fallback(command)
      "#{command}; exec $SHELL"
    end

    # Private config on a private socket: hide the status bar, keep our pane
    # titles from being overwritten by the agent shells, and bind the global
    # keys (no prefix, so they fire even while an agent pane is focused).
    #
    # Ctrl-Space toggles the manager drawer. Ctrl-w works like vim's window
    # command: it enters a one-shot `pane-nav` key table, and the next h/j/k/l
    # (or Ctrl-h/j/k/l) moves to the pane in that direction, then falls back to
    # normal input. Note: this claims Ctrl-w globally, so the agent shells lose
    # its default "delete previous word" — swap the lead key here if that bites.
    def config_tmux(exe_path, status_bar: false)
      <<~CONF
        set -g status #{status_bar ? 'on' : 'off'}
        set -g mouse on
        set -g base-index 0
        set -g pane-base-index 0
        set -g detach-on-destroy on
        setw -g automatic-rename off
        set -g allow-rename off

        # Deliver focus in/out events to pane apps, so e.g. nvim can dim itself
        # when its pane loses focus (tmux's own dim-inactive can't reach an app's
        # explicit colors — see the nvim FocusLost handler).
        set -g focus-events on

        # Pass through the extended (CSI-u / kitty) key protocol so apps that
        # negotiate it — Claude Code, editors — can tell Shift+Enter (newline)
        # from Enter (submit); without this tmux collapses both to plain Enter.
        # `on` forwards extended keys only once the app asks, and terminal-features
        # advertises the outer terminal can receive them.
        set -s extended-keys on
        set -as terminal-features 'xterm*:extkeys'

        # Solid (Unicode) borders. Normally one constant color regardless of focus
        # (the background dimming already signals which pane is active), but the
        # pane the sidebar is hovering (its @devmux_hl pane option set) gets a blue
        # border. tmux expands this format per pane when drawing inactive borders,
        # and the hovered pane is always inactive (the drawer is focused).
        set -g pane-border-lines single
        set -g pane-border-style "\#{?@devmux_hl,fg=colour39,fg=colour238}"
        set -g pane-active-border-style fg=colour238

        # A title bar on each pane's top border: the agent name (from our
        # @devmux_agent option, so Claude can't clobber it), or "devmux" for the
        # manager drawer. Room here later for CI status etc.
        set -g pane-border-status top
        set -g pane-border-format "#{pane_border_format}"

        # Wash out inactive panes with the `dim` (faint) attribute, which renders
        # the pane's own colors faintly — so it respects whatever colorscheme the
        # terminal has instead of substituting fixed colors. Plus a slightly
        # muted background. The active pane is bright (nodim) with the terminal's
        # normal background. The manager drawer is exempt via a per-pane style
        # set in UI startup.
        set -g window-style dim,bg=colour236
        set -g window-active-style nodim,bg=terminal

        bind -n #{FOCUS_KEY} run-shell "#{exe_path.shellescape} tmux-toggle"

        # Ctrl-w navigates panes — but if the focused pane is running vim/nvim,
        # forward C-w to it instead so vim's own window commands (C-w h/j/k/l)
        # work; vim crosses back into tmux at a split edge (see the matching
        # nvim mappings). Only a non-vim pane enters the pane-nav table.
        bind -n C-w if-shell -F '\#{m:*vim,\#{pane_current_command}}' 'send-keys C-w' 'switch-client -T pane-nav'
        bind -T pane-nav h select-pane -L
        bind -T pane-nav j select-pane -D
        bind -T pane-nav k select-pane -U
        bind -T pane-nav l select-pane -R
        bind -T pane-nav C-h select-pane -L
        bind -T pane-nav C-j select-pane -D
        bind -T pane-nav C-k select-pane -U
        bind -T pane-nav C-l select-pane -R
      CONF
    end

    # Pane title-bar content (literal tmux format): a solid full-width bar
    # (fill + bg) with bold centered text — the agent name from the @devmux_agent
    # option, or "devmux" for the manager (option unset).
    #
    # The bar color is driven by a per-pane @devmux_bar state option so it can be
    # flipped to grab attention later (e.g. set it to "alert" on a pane). Each
    # state is a complete literal #[...] block chosen by a conditional — commas
    # inside those blocks are escaped as `#,` since commas separate the
    # conditional's branches. All pieces are single-quoted so Ruby leaves the
    # tmux `#{...}` / `#[...]` literals alone.
    def pane_border_format
      # Prefer the display label (@devmux_label, set from context "name"), then
      # the agent slug (@devmux_agent), then the devmux title for the manager
      # (with a logo glyph when a Nerd Font is available).
      manager = Icons.logo ? "#{Icons.logo} devmux" : "devmux"
      label = '#{?#{==:#{@devmux_label},},#{?#{==:#{@devmux_agent},},' + manager +
              ',#{@devmux_agent}},#{@devmux_label}}'
      # Bar color, in precedence order: the hovered pane (@devmux_hl) is blue;
      # else a busy agent is orange; the manager and an idle agent (the default)
      # are grey. Binding does NOT change the bar color (see the marker below).
      grey   = '#[fill=colour238#,bg=colour238#,fg=colour250#,bold]'
      orange = '#[fill=colour208#,bg=colour208#,fg=colour232#,bold]'
      blue   = '#[fill=colour39#,bg=colour39#,fg=colour232#,bold]'
      agent_style = '#{?@devmux_hl,' + blue +
                    ',#{?#{==:#{@devmux_bar},busy},' + orange + ',' + grey + '}}'
      style = '#{?#{==:#{@devmux_agent},},' + grey + ',' + agent_style + '}'
      # "Server Bound" marker before the label when bound: just the message in
      # aqua (ok) / red (broken) foreground on the normal bar — no bg change. The
      # style block is re-emitted after it to restore the bar's own fg for the
      # label.
      aqua_fg   = '#[fg=colour44]'
      yellow_fg = '#[fg=colour220]'
      red_fg    = '#[fg=colour160]'
      gray_fg   = '#[fg=colour245]'
      marker = '#{?#{==:#{@devmux_bind},ok},' + aqua_fg + " #{Icons::NERD_SERVER} worktree bound  " +
               ',#{?#{==:#{@devmux_bind},dirty},' + yellow_fg + " #{Icons::NERD_SERVER_DIRTY} worktree bound (partial)  " +
               ',#{?#{==:#{@devmux_bind},binding},' + gray_fg + " #{Icons::NERD_SERVER_BINDING} worktree binding…  " +
               ',#{?#{==:#{@devmux_bind},broken},' + red_fg + " #{Icons::NERD_SERVER_BROKEN} worktree bind failed  " + ',}}}}'
      # Resource icons (ticket/PR/CI) after the label, from the @devmux_icons pane
      # option. #{E:...} re-expands it so the tmux #[fg=...] styles it carries are
      # interpreted (a plain #{...} would print them literally).
      icons = '#{E:@devmux_icons}'
      style + '#[align=centre] ' + marker + style + label + ' ' + icons
    end
  end

  # The tmux-backed control-plane backend the UI drives. Runs inside the manager
  # pane, so it identifies itself via $TMUX_PANE.
  #
  # An "agent" is a registry record (name + Claude session UUID). It may be
  # *shown* (a live tmux pane running Claude) or *hidden* (no pane; the Claude
  # conversation is saved and resumable). The registry persists so hide/show —
  # and session restarts — can reconnect a name to its Claude session.
  class TmuxBackend
    # Pane user-option holding an agent's registry name. Stable identity: unlike
    # the pane title, the program running in the pane can't overwrite it.
    AGENT_OPTION = "@devmux_agent".freeze
    # Pane user-option holding the display label shown in the title bar (the
    # context "name", falling back to the slug).
    LABEL_OPTION = "@devmux_label".freeze
    # Pane user-option holding the agent state, which drives the title-bar color.
    BAR_OPTION = "@devmux_bar".freeze
    # Pane user-option marking the pane the sidebar is hovering ("1" on that pane,
    # "" on the rest), which drives its blue highlight border + title bar.
    HL_OPTION = "@devmux_hl".freeze
    # Pane user-option holding the resource icons (ticket/PR/CI, tmux-styled) for
    # the title bar, referenced via #{E:@devmux_icons} in pane-border-format.
    ICONS_OPTION = "@devmux_icons".freeze
    # Pane user-option for the bound state ("ok" / "broken" / ""), which drives
    # the aqua/red title bar + "Server Bound" marker.
    BIND_OPTION = "@devmux_bind".freeze
    # Pane user-option marking a pane as an agent's "show" vim pane, valued with
    # the agent's name, so we keep one vim pane per agent and can find it.
    VIM_OPTION = "@devmux_vim".freeze

    # How often (seconds) the bind enforcer reconciles the main repo with the
    # bound session's worktree. Under the 3s the feature promises.
    BIND_INTERVAL = 2

    # How often (seconds) the background poller runs enabled plugins' `poll`
    # while devmux is attached, and how often it wakes to check attachment (so a
    # reattach kicks off a poll within a couple seconds rather than up to POLL_SECONDS).
    POLL_SECONDS = 30
    ATTACH_CHECK_SECONDS = 2

    def initialize(exe = nil)
      @tmux = Tmux.new
      @exe = exe
      @manager_id = Tmux.current_pane
      @state_file = File.join(TmuxSession.state_dir, "agents.json")
      @registry = Registry.new(@state_file)
      @bind_file = File.join(TmuxSession.state_dir, "bind.json")
      @bind_mutex = Mutex.new
      # Last-processed "show" request token per session uuid. Seed from existing
      # request files so stale ones from a previous run aren't re-opened.
      @show_tokens = seen_show_tokens
      # Exempt the drawer from the dim-inactive window styling: pin it to normal
      # colors so it stays readable even while an agent pane is focused. (This
      # focuses the manager as a side effect, which is fine before we show an
      # agent, since showing focuses that agent.)
      @tmux.set_pane_style(@manager_id, "nodim,bg=terminal") if @manager_id
      # Never let a failed initial spawn take down the manager — the UI should
      # still come up (empty) so you can retry — but log why.
      begin
        ensure_initial_agent
      rescue StandardError => e
        TmuxSession.log_error("initial-agent", e)
      end
      start_plugin_poller
      start_bind_enforcer
    end

    # [{ name:, display:, shown:, archived: }] in registry order — the full agent
    # list the UI organizes into active rows and the archived disclosure. `name`
    # is the stable slug used for operations; `display` is the context name (or
    # the slug) shown to the user.
    def agents
      shown = shown_panes
      bind = bind_state
      @registry.agents.map do |a|
        ctx = a["context"] || {}
        bound = !bind["uuid"].to_s.empty? && a["uuid"] == bind["uuid"]
        { name: a["name"], display: TmuxSession.display_label(a),
          display_plain: TmuxSession.display_label(a, brackets: false), state: agent_state(a),
          tickets: resource_views(ctx["tickets"], Icons.ticket),
          prs: resource_views(ctx["prs"], Icons.pr),
          shown: shown.key?(a["name"]), archived: !!a["archived"],
          has_worktree: !ctx["worktree"].to_s.empty?,
          bound: bound, bind_status: (bound ? (bind["status"] || "pending") : nil) }
      end
    end

    # Create a brand-new agent (fresh Claude session) and drop into it — you make
    # a new agent to start working in it, so collapse the drawer and focus it.
    def new_agent
      show_pane(@registry.add, focus_new: true)
    end

    # Enter on an agent row: hide the pane (kill it — Claude has saved the
    # conversation) or show it again (resuming the conversation if one exists,
    # otherwise starting fresh). Showing keeps focus in the drawer so the user
    # can keep managing sessions and Ctrl-Space over when ready.
    def toggle(name)
      record = @registry.record(name)
      return unless record
      pane = shown_panes[name]
      if pane
        close_vim_pane(name)
        hide_pane(pane)
      else
        # Showing an archived agent brings it back to the active list.
        @registry.set_archived(name, false) if record["archived"]
        show_pane(record)
      end
    end

    # Set an agent aside: close its pane (if shown) and mark it archived so it
    # moves out of the active list into the archived disclosure.
    def archive(name)
      pane = shown_panes[name]
      if pane
        close_vim_pane(name)
        @tmux.close(pane)
        TmuxSession.rebalance_agents(@tmux)
      end
      @registry.set_archived(name, true)
    end

    # Bring an archived agent back to the active list (left hidden).
    def unarchive(name)
      @registry.set_archived(name, false)
    end

    # Permanently drop an agent: close its pane (if shown) and remove its
    # registry record. The underlying Claude conversation on disk is left intact.
    def delete(name)
      pane = shown_panes[name]
      if pane
        close_vim_pane(name)
        @tmux.close(pane)
        TmuxSession.rebalance_agents(@tmux)
      end
      @registry.delete(name)
    end

    def detach
      @tmux.detach
    end

    # Highlight the pane belonging to `name` (the hovered session) with a blue
    # border + title bar, clearing the highlight on every other agent pane. Pass
    # nil to clear all (e.g. when the drawer is collapsed). Best-effort repaint.
    def highlight(name)
      shown_panes.each do |pane_name, pane_id|
        @tmux.set_pane_option(pane_id, HL_OPTION, pane_name == name ? "1" : "")
      end
      @tmux.refresh_client
    end

    # Is the manager drawer the active (focused) pane? Used to gate the hover
    # highlight so it only shows while you're actually navigating the sidebar.
    def manager_focused?
      @tmux.active_pane == @manager_id
    rescue StandardError
      true
    end

    # Widen the drawer to the expanded width and re-even the agents. Called when
    # the drawer gains focus (by any means), so its size always tracks focus.
    def expand_drawer
      TmuxSession.set_layout(@tmux, TmuxSession::EXPANDED_WIDTH)
    end

    # Shrink the drawer to the collapsed width and re-even the agents. Called when
    # the drawer loses focus.
    def collapse_drawer
      TmuxSession.set_layout(@tmux, TmuxSession::COLLAPSED_WIDTH)
    end

    # Focus the manager drawer (e.g. after a mouse click lands in it), which the
    # focus watcher then expands.
    def focus_manager
      @tmux.focus(@manager_id)
    end

    # Focus an agent's pane if it's currently shown; no-op otherwise.
    def focus_agent(name)
      pane = shown_panes[name]
      @tmux.focus(pane) if pane
    end

    # Manually open the agent's editor pane (the same split the `show` flow uses):
    # reuse the existing one if present, else split a new editor pane above the
    # agent, opened on the agent's working directory. Focuses it — a deliberate
    # "open vim" should land you in it. No-op if the agent isn't shown.
    def open_editor(name)
      agent_pane = shown_panes[name]
      return unless agent_pane
      vim = vim_pane_for(name)
      unless vim
        cwd = @tmux.pane_current_path(agent_pane)
        target = cwd.to_s.empty? ? editor : Shellwords.join([editor, cwd])
        vim = @tmux.split_above(agent_pane, target)
        @tmux.set_pane_option(vim, VIM_OPTION, name)
      end
      @tmux.focus(vim)
    end

    # Rename a session (set its context "name"); updates the pane title too.
    def rename(name, title)
      record = @registry.record(name)
      return unless record
      @registry.write_context(record["uuid"], "name", title)
      sync_panes
    end

    # Publish the currently-hovered agent name so a Ctrl-Space collapse can focus
    # its pane (see toggle!). "" when nothing agent-like is selected.
    def publish_hover(name)
      @tmux.set_option(TmuxSession::HOVER_OPTION, name.to_s)
    end

    # Read (and clear) the agent that toggle! asked the sidebar to select on
    # expand, or nil if none is pending.
    def take_select
      value = @tmux.get_option(TmuxSession::SELECT_OPTION)
      return nil if value.to_s.empty?
      @tmux.set_option(TmuxSession::SELECT_OPTION, "")
      value
    end

    # Open the browser URL for a resource id (a clicked ticket/PR icon), via the
    # owning plugin. No-op if the plugin can't resolve a URL.
    def open_resource(identifier)
      url = Plugins.resource_url(identifier)
      TmuxSession.open_url(url) if url
    end

    # Open the plugins menu in a centered popup. Runs `devmux plugins-menu` (its
    # own process), which toggles the shared plugins store; nothing here needs to
    # change since the sidebar doesn't render plugin state — the popup just needs
    # to float over the window. Sized to the plugin count plus room for the title
    # and hints.
    def open_plugins
      bin = @exe || "devmux"
      # Large and generously padded, with the content centered inside (the menu
      # centers on both axes). A heavy, orange border makes it feel like a proper
      # dialog floating over the window.
      @tmux.display_popup("#{bin.shellescape} plugins-menu",
                          width: 64, height: 22, border: "heavy",
                          border_style: "fg=colour208")
    end

    # Newest mtime across the registry file, plugin data files, and the bind file,
    # so the UI notices external changes and refreshes without a keypress —
    # whether that's an agent writing its own context (registry), a plugin poll
    # caching state (plugin store), or the bind enforcer flipping ok/broken.
    def state_mtime
      files = [@state_file, @bind_file] +
              Dir.glob(File.join(TmuxSession.state_dir, "plugin-*.json")) +
              Dir.glob(File.join(TmuxSession.state_dir, "show-*.json"))
      files.map { |f| File.mtime(f) rescue nil }.compact.max
    end

    # Act on any new `devmux show` requests: open (or reuse) a vim pane above the
    # requesting agent, on the given file/lines. Called from the UI loop when the
    # state files change. Idempotent via per-session request tokens.
    def process_show_requests
      Dir.glob(File.join(TmuxSession.state_dir, "show-*.json")).each do |path|
        uuid = File.basename(path, ".json").sub(/\Ashow-/, "")
        request = JSON.parse(File.read(path)) rescue nil
        next unless request
        next if @show_tokens[uuid] == request["token"]
        @show_tokens[uuid] = request["token"]
        reveal_in_vim(uuid, request)
      end
    rescue StandardError => e
      TmuxSession.log_error("show", e)
    end

    # Bind (toggle) the session `name` to the main repo: its worktree gets checked
    # out (detached) in the main working tree so you can QA it there. Binding a
    # session replaces any previous one; binding the already-bound session unbinds
    # it. Only sessions with a recorded worktree can bind. Enforces immediately so
    # the checkout happens on the keypress, not up to BIND_INTERVAL later.
    def toggle_bind(name)
      record = @registry.record(name)
      return unless record
      return if record["archived"] # can't bind an archived session
      uuid = record["uuid"]
      worktree = (record["context"] || {})["worktree"]
      if bind_state["uuid"] == uuid
        # Unbind: clear immediately (markers vanish now), then restore the main
        # repo to its primary branch off the UI thread — the checkout can be slow.
        write_bind_state({})
        Thread.new { @bind_mutex.synchronize { restore_main_branch(worktree) } }
      else
        return if worktree.to_s.empty? # can't bind a session with no worktree
        # Mark "binding" right away (a fast file write) and let the background
        # enforcer do the actual checkout on its next tick — never block the UI on
        # git here.
        write_bind_state({ "uuid" => uuid, "status" => "binding" })
      end
    end

    def bind_state
      JSON.parse(File.read(@bind_file))
    rescue StandardError
      {}
    end

    # Reconcile the main repo with the bound session's worktree HEAD. Runs on the
    # keypress and every BIND_INTERVAL from the enforcer thread; mutex-guarded so
    # those two never run git in the same repo at once. Updates the stored status
    # (ok/broken) only on change, so the UI repaints (via state_mtime) just then.
    def enforce_bind
      @bind_mutex.synchronize do
        state = bind_state
        uuid = state["uuid"].to_s
        return if uuid.empty?
        record = @registry.record(uuid)
        worktree = record && (record["context"] || {})["worktree"]
        status = bind_status(worktree)
        write_bind_state({ "uuid" => uuid, "status" => status }) if status != state["status"]
      end
    end

    # "broken" if the checkout can't apply; else "dirty" if the worktree has
    # uncommitted changes the commit checkout doesn't capture; else "ok".
    def bind_status(worktree)
      return "broken" unless apply_bind(worktree)
      worktree_dirty?(worktree) ? "dirty" : "ok"
    end

    def worktree_dirty?(worktree)
      status = git(worktree, "status", "--porcelain")
      !status.nil? && !status.empty?
    end

    # Detach-checkout the worktree's HEAD in its main working tree. Returns true
    # when the main repo already matches or the checkout succeeds; false when we
    # can't (no worktree, not a repo, or the checkout is refused — e.g. a dirty
    # tree with conflicting local changes).
    def apply_bind(worktree)
      return false if worktree.to_s.empty?
      wt_sha = git(worktree, "rev-parse", "HEAD")
      main = main_worktree(worktree)
      return false unless wt_sha && main
      main_sha = git(main, "rev-parse", "HEAD")
      return true if main_sha == wt_sha
      git_ok?(main, "checkout", "--detach", wt_sha)
    end

    # On unbind, put the main repo back on its primary branch (once). While bound
    # it sat detached at the worktree's commit; checking out the branch re-attaches
    # it. Best-effort — a dirty tree that refuses the switch is left as-is.
    def restore_main_branch(worktree)
      return if worktree.to_s.empty?
      main = main_worktree(worktree)
      return unless main
      branch = primary_branch(main)
      git_ok?(main, "checkout", branch) if branch
    end

    # The repo's primary branch: origin's default (origin/HEAD) if known, else
    # whichever of main/master exists locally, else nil.
    def primary_branch(repo)
      ref = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
      return ref.sub(%r{\Aorigin/}, "") if ref && !ref.empty?
      %w[main master].find { |b| git_ok?(repo, "rev-parse", "--verify", "--quiet", b) }
    end

    # The main working tree for a (linked) worktree: the parent of its common git
    # dir. For the main worktree itself this is just itself.
    def main_worktree(worktree)
      common = git(worktree, "rev-parse", "--git-common-dir")
      return nil unless common
      common = File.expand_path(common, worktree)
      File.basename(common) == ".git" ? File.dirname(common) : nil
    end

    def git(dir, *args)
      out, _err, status = Open3.capture3("git", "-C", dir, *args)
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    def git_ok?(dir, *args)
      _out, _err, status = Open3.capture3("git", "-C", dir, *args)
      status.success?
    rescue StandardError
      false
    end

    # Open (or reuse) the agent's vim "show" pane on a file/line-range. One vim
    # pane per agent: if it already exists we `:drop` the file into it; otherwise
    # we split a new pane above the agent and launch vim there. The agent must be
    # visible (its pane exists) to attach to.
    def reveal_in_vim(uuid, request)
      record = @registry.record(uuid)
      return unless record
      name = record["name"]
      agent_pane = shown_panes[name]
      return unless agent_pane
      file = request["file"].to_s
      return if file.empty?
      start = request["start"]
      finish = request["end"]
      vim = vim_pane_for(name)
      if vim
        reuse_vim(vim, file, start, finish)
      else
        id = @tmux.split_above(agent_pane, vim_launch_command(file, start, finish))
        @tmux.set_pane_option(id, VIM_OPTION, name)
      end
    end

    def vim_pane_for(name)
      pane = @tmux.panes.find { |p| p[:vim] == name }
      pane && pane[:id]
    end

    def close_vim_pane(name)
      pane = vim_pane_for(name)
      @tmux.close(pane) if pane
    end

    def vim_launch_command(file, start, finish)
      Shellwords.join([editor, file, "-c", vim_reveal_ex(start, finish)])
    end

    # The editor binary to launch. tmux runs the pane command non-interactively,
    # so a shell alias like `vim=nvim` isn't visible — pick an explicit binary:
    # DEVMUX_EDITOR if set, else nvim when it's on PATH (so a neovim user's config
    # loads), else vim. Must be a vim-family editor (we drive it with Ex commands
    # and :drop).
    def editor
      override = ENV["DEVMUX_EDITOR"].to_s
      return override unless override.empty?
      on_path?("nvim") ? "nvim" : "vim"
    end

    def on_path?(cmd)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                 .any? { |dir| File.executable?(File.join(dir, cmd)) }
    rescue StandardError
      false
    end

    # Drive an already-open vim to the file/range: normal mode, `:drop` the file,
    # then run the reveal Ex command.
    def reuse_vim(vim, file, start, finish)
      @tmux.send_keys(vim, "Escape")
      @tmux.send_text(vim, ":drop #{vim_escape(file)}")
      @tmux.send_keys(vim, "Enter")
      @tmux.send_text(vim, ":#{vim_reveal_ex(start, finish)}")
      @tmux.send_keys(vim, "Enter")
    end

    # An Ex command that clears old highlights and, when a range is given, jumps
    # to it, highlights lines start..finish (a matchadd, so it persists), and
    # centers. Uses the Search group for a visible highlight.
    def vim_reveal_ex(start, finish)
      return "call clearmatches()" unless start
      pattern = "\\%>#{start - 1}l\\%<#{finish + 1}l"
      "#{start} | call clearmatches() | call matchadd('Search', '#{pattern}') | normal! zz"
    end

    # Escape characters special on vim's command line (for `:drop <file>`).
    def vim_escape(path)
      path.gsub(/[ \\%#|"]/) { |c| "\\#{c}" }
    end

    def seen_show_tokens
      Dir.glob(File.join(TmuxSession.state_dir, "show-*.json")).each_with_object({}) do |path, acc|
        uuid = File.basename(path, ".json").sub(/\Ashow-/, "")
        request = JSON.parse(File.read(path)) rescue next
        acc[uuid] = request["token"]
      end
    rescue StandardError
      {}
    end

    # Background thread that runs enabled plugins' `poll` every POLL_SECONDS.
    # Isolated from the UI (it only touches the mutex-guarded registry and each
    # plugin's own store), so a slow `gh` call never blocks the sidebar; the UI
    # picks up its writes via state_mtime. Per-plugin failures are logged, not
    # fatal. A daemon thread — it dies with the manager process.
    # Poll only while devmux is actually attached (a client is looking) — the
    # manager process keeps running under the detached tmux server, so without
    # this the poller would keep hitting the network in the background after you
    # quit. Polls immediately when a client attaches (first open *and* reattach),
    # then every POLL_SECONDS while it stays attached; pauses when detached.
    def start_plugin_poller
      @poller = Thread.new do
        was_attached = false
        last_poll = nil
        loop do
          begin
            attached = tmux_attached?
            if attached
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              just_attached = !was_attached
              due = last_poll.nil? || (now - last_poll) >= POLL_SECONDS
              if just_attached || due
                Plugins.run_poll(@registry, logger: ->(m) { TmuxSession.log_plugin(m) })
                last_poll = now
              end
            end
            was_attached = attached
          rescue StandardError => e
            TmuxSession.log_error("plugin-poller", e)
          end
          sleep ATTACH_CHECK_SECONDS
        end
      end
    end

    def tmux_attached?
      @tmux.clients_attached.positive?
    rescue StandardError
      false
    end

    # Push each shown agent's display name and state into its pane title bar
    # (name + state color). The agent can't do this itself — its Bash sandbox
    # blocks the tmux socket — so the manager does it when it notices a change.
    def sync_panes
      by_name = @registry.agents.each_with_object({}) { |a, h| h[a["name"]] = a }
      bind = bind_state
      shown_panes.each do |name, pane_id|
        record = by_name[name]
        next unless record
        @tmux.set_pane_option(pane_id, LABEL_OPTION, TmuxSession.display_label(record))
        @tmux.set_pane_option(pane_id, BAR_OPTION, agent_state(record))
        @tmux.set_pane_option(pane_id, ICONS_OPTION, TmuxSession.title_icons(record))
        @tmux.set_pane_option(pane_id, BIND_OPTION, bind_marker(record, bind))
      end
      # Repaint now so the new colors show immediately, not on tmux's next tick.
      @tmux.refresh_client
    end

    # The @devmux_bind value for a pane: "ok"/"broken"/"pending" if this record is
    # the bound session, else "" (clears any prior marker).
    def bind_marker(record, bind = bind_state)
      return "" if bind["uuid"].to_s.empty? || record["uuid"] != bind["uuid"]
      bind["status"] || "pending"
    end

    # Persist bind state atomically ({} clears it). Pushes the new marker onto the
    # panes right away so the aqua/red flips immediately, not on the next tick.
    def write_bind_state(state)
      tmp = "#{@bind_file}.tmp"
      File.write(tmp, JSON.pretty_generate(state))
      File.rename(tmp, @bind_file)
      sync_panes
    rescue StandardError => e
      TmuxSession.log_error("bind-write", e)
    end

    # Background thread that reconciles the main repo with the bound worktree
    # every BIND_INTERVAL, while devmux is attached (same reasoning as the poller
    # — don't run git in the user's repo in the background after they've quit).
    def start_bind_enforcer
      @binder = Thread.new do
        loop do
          begin
            enforce_bind if tmux_attached?
          rescue StandardError => e
            TmuxSession.log_error("bind-enforcer", e)
          end
          sleep BIND_INTERVAL
        end
      end
    end

    private

    # On a fresh registry, create agent-1. On a restarted session with active
    # agents but nothing shown yet, resume the first active one so the user lands
    # on something rather than an empty screen (archived agents stay put). Either
    # way we focus the agent (collapsing the drawer) so it's immediately usable.
    def ensure_initial_agent
      return unless shown_panes.empty?
      active = @registry.agents.reject { |a| a["archived"] }
      record = active.first || @registry.add
      show_pane(record, focus_new: true)
    end

    # Show a pane for a registry record: split to the right of the rightmost
    # pane, tag it with its slug (stable identity) and display label, set
    # DEVMUX_SESSION so the agent can address itself in `devmux context`, and
    # re-even the agents. By default focus stays on the manager (the drawer stays
    # open for continued navigation); with focus_new the drawer collapses and we
    # land in the new pane.
    def show_pane(record, focus_new: false)
      name = record["name"]
      env = { "DEVMUX_SESSION" => record["uuid"] }
      env["DEVMUX_BIN"] = @exe if @exe
      id = @tmux.split_right(target: rightmost_pane, cwd: agent_cwd,
                             command: TmuxSession.agent_command(record["uuid"], exe: @exe),
                             name: name, env: env)
      @tmux.set_pane_option(id, AGENT_OPTION, name)
      @tmux.set_pane_option(id, LABEL_OPTION, TmuxSession.display_label(record))
      @tmux.set_pane_option(id, BAR_OPTION, agent_state(record))
      @tmux.set_pane_option(id, ICONS_OPTION, TmuxSession.title_icons(record))
      @tmux.set_pane_option(id, BIND_OPTION, bind_marker(record))
      if focus_new
        TmuxSession.set_layout(@tmux, TmuxSession::COLLAPSED_WIDTH)
        @tmux.focus(id)
      else
        TmuxSession.rebalance_agents(@tmux)
        # split-window focused the new pane; return focus to the drawer.
        @tmux.focus(@manager_id)
      end
      id
    end

    # One view per identifier whose scheme is currently valid (an enabled
    # plugin's): { id:, icons: [{ glyph:, color: }, ...] }. The base glyph is the
    # generic ticket/PR icon, colored by the owning plugin's resource_details
    # (nil = default); a plugin may append extra decoration icons (e.g. github's
    # CI pass/fail glyph). Toggling a plugin makes its icons appear/disappear, and
    # its polled state recolors/decorates them — all without touching context.
    def resource_views(value, base_glyph)
      Array(value).select { |id| Providers.valid?(id) }.map do |id|
        details = Plugins.resource_details(id)
        icons = []
        if base_glyph
          glyph = (details && details[:glyph]) || base_glyph
          icons << { glyph: glyph, color: details && details[:color] }
        end
        Array(details && details[:icons]).each do |icon|
          icons << { glyph: icon[:glyph], color: icon[:color] }
        end
        { id: id, icons: icons, label: resource_label(id, details),
          annotation: details && details[:annotation] }
      end
    end

    # A text label for a resource in the expanded tree: the short id (MAT-123,
    # themis#1514) plus the plugin's title if it has one.
    def resource_label(id, details = Plugins.resource_details(id))
      short = Providers.short(id)
      title = details && details[:title]
      title.to_s.empty? ? short : "#{short} #{title}"
    end

    # Where to open agent panes: the directory devmux was launched from (recorded
    # as a session option in launch!), so agents run in *your* project — e.g.
    # `cd ~/src/themis && ~/src/devmux/bin/devmux` opens agents in themis, not in
    # devmux. Falls back to the manager pane's cwd, then Dir.pwd.
    def agent_cwd
      dir = @tmux.get_option(TmuxSession::LAUNCH_DIR_OPTION)
      return dir if dir && !dir.empty? && File.directory?(dir)
      path = @manager_id && @tmux.pane_current_path(@manager_id)
      path && !path.empty? ? path : Dir.pwd
    rescue StandardError
      Dir.pwd
    end

    # The agent's state (drives the title-bar color), defaulting to needs_input
    # (a fresh agent is waiting for you).
    def agent_state(record)
      state = (record["context"] || {})["agent_state"]
      state && !state.to_s.empty? ? state : "needs_input"
    end

    # Hide a pane: kill it and re-even the survivors. Focus stays on the manager
    # (where the user pressed Enter), so the list keeps navigating.
    def hide_pane(pane_id)
      @tmux.close(pane_id)
      TmuxSession.rebalance_agents(@tmux)
    end

    # { agent_name => pane_id } for currently-shown agent panes, keyed by the
    # stable @devmux_agent option (not the mutable title). Re-queried from tmux,
    # so it always reflects reality.
    def shown_panes
      @tmux.panes.each_with_object({}) do |p, h|
        h[p[:agent]] = p[:id] if p[:agent]
      end
    end

    def rightmost_pane
      shown = @tmux.panes.select { |p| p[:agent] }
      shown.empty? ? @manager_id : shown.last[:id]
    end
  end
end
