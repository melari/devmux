module Devmux
  module Plugins
    # The Slack plugin. Unlike github/linear (which register schemes for the
    # built-in tickets/prs keys), this one contributes a whole new *context key* —
    # `slack_threads` — via `context_keys`, showing how a plugin can extend the
    # context schema, not just supply examples for existing keys.
    #
    # A thread is stored as a scheme-prefixed id `slack:<workspace>/<channel>/<ts>`
    # (from a URL like https://clio.slack.com/archives/CLWTL3KPX/p178789...), which
    # `resource_url` turns back into that URL to open. Its sidebar/title icon is the
    # Slack glyph in purple.
    class Slack
      COLOR = "38;5;99".freeze # purple
      GLYPH = "\u{f198}".freeze

      def id
        "slack"
      end

      def name
        "Slack"
      end

      def logo
        GLYPH
      end

      def provider
        {
          scheme: "slack",
          # workspace / channel / message-ts, e.g. clio/CLWTL3KPX/p1787892747214499
          body: %r{\A[\w.-]+/[A-Z0-9]+/p\d+\z},
          short: lambda do |body|
            _workspace, channel, = body.split("/")
            "##{channel}"
          end,
        }
      end

      # The new context key this plugin adds to the schema (merged into
      # Devmux::Context when the plugin is enabled).
      def context_keys
        {
          "slack_threads" => {
            default: [], array: true, identifier: true,
            description: "Slack threads as scheme-prefixed ids " \
                         "slack:workspace/channel/ts (from a thread URL). Multiple allowed. See examples.",
          },
        }
      end

      def examples_for(key)
        key == "slack_threads" ? ["slack:clio/CLWTL3KPX/p1787892747214499"] : []
      end

      # Every slack id gets the purple Slack glyph (the scheme already scoped this
      # call to slack ids via Plugins.for_identifier).
      def resource_details(_identifier)
        { glyph: GLYPH, color: COLOR }
      end

      # Rebuild the thread URL to open in the browser.
      def resource_url(identifier)
        _scheme, body = identifier.to_s.split(":", 2)
        workspace, channel, ts = body.to_s.split("/")
        return nil unless workspace && channel && ts
        "https://#{workspace}.slack.com/archives/#{channel}/#{ts}"
      end
    end
  end
end
