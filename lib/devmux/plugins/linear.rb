module Devmux
  module Plugins
    # The Linear plugin: registers the `linear:` identifier scheme (issue keys
    # like MAT-123) and seeds the `tickets` context key with an example.
    #
    # A plugin is just an object responding to the devmux plugin interface (see
    # Devmux::Plugins) — it does NOT subclass anything, so a third-party plugin
    # can implement the same shape without any devmux base class on hand.
    class Linear
      def id
        "linear"
      end

      def name
        "Linear"
      end

      def logo
        "\u{f145}" # nf-fa-ticket
      end

      def provider
        {
          scheme: "linear",
          body: /\A[A-Z][A-Z0-9]*-\d+\z/,
          short: ->(body) { body },
        }
      end

      def examples_for(key)
        key == "tickets" ? ["linear:MAT-123"] : []
      end

      # Browser URL for a Linear issue. Linear URLs are workspace-scoped
      # (linear.app/<workspace>/issue/MAT-123) and the workspace isn't part of the
      # identifier, so it's read from DEVMUX_LINEAR_WORKSPACE; without it we can't
      # build a URL (returns nil, and open is a no-op).
      def resource_url(identifier)
        workspace = ENV["DEVMUX_LINEAR_WORKSPACE"].to_s
        return nil if workspace.empty?
        _scheme, key = identifier.to_s.split(":", 2)
        return nil if key.to_s.empty?
        "https://linear.app/#{workspace}/issue/#{key}"
      end
    end
  end
end
