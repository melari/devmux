require "open3"

module Devmux
  # Thin wrapper over the `tmux` CLI.
  # All commands run against a private socket (-L) so devmux never collides with
  # the user's own tmux server or config.
  class Tmux
    class Error < StandardError; end

    SOCKET = "devmux".freeze
    SESSION = "devmux".freeze

    # Tab-separated so titles with spaces survive; \#{...} is a literal tmux
    # format string (escaped so Ruby doesn't interpolate it). The trailing
    # @devmux_agent is our own pane user-option — a stable identity that the
    # program in the pane can't overwrite the way it can the title.
    PANE_FMT = "\#{pane_id}\t\#{pane_title}\t\#{pane_width}\t\#{pane_left}\t\#{pane_active}\t\#{@devmux_agent}\t\#{@devmux_vim}".freeze

    def self.available?
      system("tmux", "-V", out: File::NULL, err: File::NULL)
    end

    def self.inside_session?
      ENV.key?("TMUX")
    end

    # The pane this process is running in. tmux sets TMUX_PANE per pane, so the
    # manager UI knows its own pane id without any lookup.
    def self.current_pane
      ENV["TMUX_PANE"]
    end

    def initialize(session: SESSION)
      @session = session
    end

    def has_session?
      system("tmux", "-L", SOCKET, "has-session", "-t", @session,
             out: File::NULL, err: File::NULL)
    end

    # Every pane in the session, left-to-right:
    # [{ id:, title:, width:, left:, active:, agent: }] — agent is our
    # @devmux_agent user-option (nil when unset, e.g. the manager pane).
    def panes
      capture("list-panes", "-t", @session, "-F", PANE_FMT).each_line.map do |line|
        id, title, width, left, active, agent, vim = line.chomp.split("\t", -1)
        { id: id, title: title, width: width.to_i, left: left.to_i,
          active: active == "1", agent: (agent.nil? || agent.empty? ? nil : agent),
          vim: (vim.nil? || vim.empty? ? nil : vim) }
      end.sort_by { |p| p[:left] }
    end

    # The working directory of a pane (what tmux would use for a new split there).
    def pane_current_path(pane_id)
      capture("display-message", "-p", "-t", pane_id, "\#{pane_current_path}").strip
    end

    def window_width
      capture("display-message", "-p", "-t", @session, "\#{window_width}").strip.to_i
    end

    # The id of the session's currently-active (focused) pane.
    def active_pane
      capture("display-message", "-p", "-t", @session, "\#{pane_id}").strip
    end

    # Number of clients currently attached to the session (0 when devmux is
    # detached/backgrounded — the server and panes live on, but nobody's looking).
    def clients_attached
      capture("display-message", "-p", "-t", @session, "\#{session_attached}").strip.to_i
    rescue Error
      0
    end

    # Start the server + session detached, running `command` in its single
    # (manager) pane. -f loads our private config; only takes effect here, when
    # the server is first created.
    def new_session(config:, cwd:, command:, cols:, rows:)
      run("-f", config, "new-session", "-d", "-s", @session,
          "-x", cols.to_s, "-y", rows.to_s, "-c", cwd, command)
    end

    # Split `target` vertically, placing the new pane to its right; returns the
    # new pane's id. tmux focuses the new pane by default. `env` sets pane
    # environment variables (-e KEY=VAL).
    def split_right(target:, cwd:, command:, name:, env: {})
      args = ["split-window", "-h", "-t", target, "-c", cwd, "-P", "-F", "\#{pane_id}"]
      env.each { |key, value| args += ["-e", "#{key}=#{value}"] }
      args << command
      id = capture(*args).strip
      set_title(id, name)
      id
    end

    # Split `target` vertically placing the new pane ABOVE it, without moving
    # focus (-d), running `command`. Returns the new pane's id. Used for the vim
    # "show" pane above an agent.
    def split_above(target, command)
      capture("split-window", "-v", "-b", "-d", "-t", target,
              "-P", "-F", "\#{pane_id}", command).strip
    end

    # Send named keys (e.g. "Enter", "Escape") to a pane.
    def send_keys(pane_id, *keys)
      run("send-keys", "-t", pane_id, *keys)
    end

    # Send literal text (-l) to a pane, as if typed.
    def send_text(pane_id, text)
      run("send-keys", "-t", pane_id, "-l", text)
    end

    def set_title(pane_id, title)
      run("select-pane", "-t", pane_id, "-T", title)
    end

    # Set a pane user-option (@name) — a stable identity marker unaffected by the
    # program running in the pane.
    def set_pane_option(pane_id, name, value)
      run("set-option", "-p", "-t", pane_id, name, value)
    end

    # A per-pane style (-P) that overrides window-style/window-active-style for
    # this one pane — used to exempt the manager drawer from the dim-inactive
    # styling. Note: like select-pane in general, this also focuses the pane.
    def set_pane_style(pane_id, style)
      run("select-pane", "-t", pane_id, "-P", style)
    end

    def focus(pane_id)
      run("select-pane", "-t", pane_id)
    end

    # Return focus to the previously-active pane (tmux's "last" pane).
    def focus_last
      run("select-pane", "-t", @session, "-l")
    end

    # Absolute width in columns.
    def resize_width(pane_id, cols)
      run("resize-pane", "-t", pane_id, "-x", cols.to_s)
    end

    # Run several tmux commands in ONE invocation (separated by `;`), so tmux
    # applies them all and redraws once — avoiding the flicker of resizing panes
    # one at a time. `commands` is an array of arg arrays, e.g.
    # [["resize-pane","-t","%1","-x","44"], ["resize-pane","-t","%2","-x","91"]].
    def batch(commands)
      commands = commands.reject(&:empty?)
      return if commands.empty?
      args = []
      commands.each_with_index do |cmd, i|
        args << ";" unless i.zero?
        args.concat(cmd)
      end
      run(*args)
    end

    def close(pane_id)
      run("kill-pane", "-t", pane_id)
    end

    def detach
      run("detach-client", "-s", @session)
    end

    def kill_session
      run("kill-session", "-t", @session)
    end

    # Show a centered floating popup running `command`, closing it when the
    # command exits (-E). Blocks until it closes. Used for the plugins menu, which
    # should float over the whole window rather than live in the narrow drawer.
    # `border` picks the border-line style (single/double/heavy/rounded/…);
    # `border_style` is a tmux style string for the border's color.
    def display_popup(command, width: nil, height: nil, border: nil, border_style: nil)
      args = ["display-popup", "-E"]
      args += ["-w", width.to_s] if width
      args += ["-h", height.to_s] if height
      args += ["-b", border] if border
      args += ["-S", border_style] if border_style
      args << command
      run(*args)
    end

    # Force attached clients to redraw now. Pane borders (and the title-bar
    # colors in pane-border-format) otherwise only repaint on tmux's own
    # schedule, so a state change can look laggy until the next repaint.
    # Best-effort: a detached session has "no current client" — nothing to draw.
    def refresh_client
      run("refresh-client")
    rescue Error
      nil
    end

    # Session-scoped user options (@name) — used to stamp a session with the
    # devmux version it was created from, so a relaunch can detect an update.
    def set_option(name, value)
      run("set-option", "-t", @session, name, value)
    end

    def get_option(name)
      capture("show-options", "-t", @session, "-v", name).strip
    rescue Error
      ""
    end

    private

    def run(*args)
      _out, err, status = Open3.capture3("tmux", "-L", SOCKET, *args)
      raise Error, "tmux #{args.join(' ')} failed: #{err.strip}" unless status.success?
      nil
    end

    def capture(*args)
      out, err, status = Open3.capture3("tmux", "-L", SOCKET, *args)
      raise Error, "tmux #{args.join(' ')} failed: #{err.strip}" unless status.success?
      out
    end
  end
end
