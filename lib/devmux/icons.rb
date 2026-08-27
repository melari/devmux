module Devmux
  # Sidebar glyphs. When a Nerd Font is available we use its icons (agent,
  # ticket, pull-request); otherwise we fall back to a plain glyph for the agent
  # and simply omit the association icons.
  #
  # Detection is best-effort (we can't know the terminal's configured font, only
  # what's installed); override with DEVMUX_NERD_FONT=1/0.
  module Icons
    # Nerd Font codepoints (from the authoritative glyphnames list):
    #   agent  = nf-cod-claude   (recent Codicon; needs a current Nerd Font)
    #   ticket = nf-fa-ticket
    #   pr     = nf-oct-git_pull_request
    NERD_AGENT    = "\u{ec82}".freeze
    NERD_TICKET   = "\u{f145}".freeze
    NERD_PR       = "\u{f407}".freeze
    NERD_SELECTOR = "\u{f0a03}".freeze # md- arrow, used as the selection cursor
    NERD_LOGO     = "\u{f44f}".freeze  # glyph shown before the devmux title
    PLAIN_AGENT   = "✦".freeze

    # Checkbox glyphs (not Nerd Font — always available). Shared by the sidebar
    # (pane open/closed) and the plugins menu (plugin on/off) so they look alike.
    CHECK_ON  = "▣".freeze
    CHECK_OFF = "□".freeze

    # Server marker for a "bound" session (its worktree checked out in the main
    # repo): the healthy server; a warning server when the worktree is dirty (has
    # uncommitted changes the commit checkout doesn't reflect); the broken server
    # when the bind can't apply at all.
    NERD_SERVER         = "\u{f233}".freeze
    NERD_SERVER_DIRTY   = "\u{ec6c}".freeze
    NERD_SERVER_BROKEN  = "\u{f0491}".freeze
    NERD_SERVER_BINDING = "\u{f251}".freeze # in progress (checkout pending)

    module_function

    def nerd?
      return @nerd unless @nerd.nil?
      @nerd =
        case ENV["DEVMUX_NERD_FONT"]&.downcase
        when "1", "true", "yes", "on" then true
        when "0", "false", "no", "off" then false
        else detect
        end
    end

    # DEVMUX_ICON_AGENT overrides the agent glyph (a literal char), for fonts
    # without nf-cod-claude yet, or a different preference.
    def agent
      override = ENV["DEVMUX_ICON_AGENT"]
      return override if override && !override.empty?
      nerd? ? NERD_AGENT : PLAIN_AGENT
    end

    def ticket
      NERD_TICKET if nerd?
    end

    def pr
      NERD_PR if nerd?
    end

    def selector
      nerd? ? NERD_SELECTOR : ">"
    end

    # The glyph shown before the devmux title, or nil without a Nerd Font.
    def logo
      NERD_LOGO if nerd?
    end

    # Bound-session server marker (healthy / broken), or nil without a Nerd Font.
    def server
      NERD_SERVER if nerd?
    end

    def server_dirty
      NERD_SERVER_DIRTY if nerd?
    end

    def server_broken
      NERD_SERVER_BROKEN if nerd?
    end

    def server_binding
      NERD_SERVER_BINDING if nerd?
    end

    # Display columns a Nerd Font icon occupies. Non-Mono variants draw icons
    # ~2 cells wide, so we reserve 2 (a trailing space) to avoid overlap.
    def width
      nerd? ? 2 : 1
    end

    # Look for an installed Nerd Font file (they share codepoints across fonts).
    def detect
      dirs = [
        File.join(Dir.home, "Library", "Fonts"), "/Library/Fonts", "/System/Library/Fonts",
        File.join(Dir.home, ".local", "share", "fonts"), "/usr/share/fonts", "/usr/local/share/fonts"
      ]
      patterns = dirs.flat_map { |d| ["#{d}/*Nerd*", "#{d}/*/*Nerd*"] }
      Dir.glob(patterns, File::FNM_CASEFOLD).any?
    rescue StandardError
      false
    end
  end
end
