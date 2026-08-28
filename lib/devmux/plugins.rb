require "json"
require "fileutils"
require "devmux/plugin_host"
require "devmux/plugins/github"
require "devmux/plugins/linear"
require "devmux/plugins/slack"

module Devmux
  # The devmux plugin registry: the set of loaded plugins plus which of them are
  # enabled. It's the seam the rest of the app queries — Providers pulls its
  # identifier schemes from here, Context pulls its per-key examples, and the
  # backend resolves per-resource icon colors — so toggling a plugin changes all
  # of them at once.
  #
  # A plugin is any object responding to the interface below; it does NOT inherit
  # from a devmux base class, so a third-party plugin (loaded from its own .rb)
  # only has to implement the shape. Every optional method is guarded here with
  # respond_to?, so a minimal plugin (just id + name) is valid.
  #
  #   id                       -> String  (stable slug; required)
  #   name                     -> String  (menu label; required)
  #   logo                     -> String  Nerd Font glyph, or nil
  #   provider                 -> { scheme:, body:, short: } identifier scheme, or nil
  #   examples_for(key)        -> [String] example ids contributed for a context key
  #   resource_details(id)     -> { state:, color: } for one of its identifiers, or nil
  #   poll(host)               -> background sync (see Devmux::PluginHost)
  #
  # Enabled/disabled state persists as JSON under the state dir, read fresh on
  # every query (never cached): the plugins menu runs in a separate process (a
  # tmux popup) from the manager UI and the `devmux context` CLI, and all must
  # see each other's writes.
  module Plugins
    BUILTIN = [Github.new, Linear.new, Slack.new].freeze

    module_function

    def all
      BUILTIN
    end

    def find(id)
      all.find { |p| p.id == id }
    end

    def enabled
      all.reject { |p| disabled.include?(p.id) }
    end

    def enabled?(id)
      !disabled.include?(id)
    end

    def toggle(id)
      return unless find(id)
      list = disabled
      list.include?(id) ? list.delete(id) : (list << id)
      save(list)
    end

    # Identifier-provider defs from enabled plugins (consumed by Providers).
    def providers
      enabled.select { |p| p.respond_to?(:provider) }.map(&:provider).compact
    end

    # Example identifier strings for a context key, across enabled plugins.
    def examples_for(key)
      enabled.select { |p| p.respond_to?(:examples_for) }.flat_map { |p| p.examples_for(key) }
    end

    # Context keys contributed by enabled plugins (merged into Context's schema),
    # e.g. slack's `slack_threads`. { key => spec } like Context::KEYS entries.
    def context_keys
      enabled.select { |p| p.respond_to?(:context_keys) }
             .reduce({}) { |acc, p| acc.merge(p.context_keys) }
    end

    # The enabled plugin owning an identifier's scheme, or nil. (Splits the
    # scheme itself rather than going through Providers, which depends on us.)
    def for_identifier(identifier)
      scheme = identifier.to_s.split(":", 2).first
      enabled.find do |p|
        p.respond_to?(:provider) && p.provider && p.provider[:scheme] == scheme
      end
    end

    # Live details for a resource id from its owning plugin — a hash that may
    # carry `:color` (styling the base ticket/PR glyph) and `:icons` (extra
    # decoration icons, each `{glyph:, color:}`). nil when unknown.
    def resource_details(identifier)
      plugin = for_identifier(identifier)
      return nil unless plugin && plugin.respond_to?(:resource_details)
      plugin.resource_details(identifier)
    rescue StandardError
      nil
    end

    # Browser URL for a resource id, from its owning plugin's resource_url, or
    # nil when unknown / the plugin can't resolve it (e.g. linear, which needs a
    # workspace we don't have). Used by click-to-open.
    def resource_url(identifier)
      plugin = for_identifier(identifier)
      return nil unless plugin && plugin.respond_to?(:resource_url)
      plugin.resource_url(identifier)
    rescue StandardError
      nil
    end

    # Enabled plugins that do background polling.
    def pollable
      enabled.select { |p| p.respond_to?(:poll) }
    end

    # Run one poll cycle: every enabled pollable plugin's `poll`, handed a
    # PluginHost over `registry`. `logger` (a ->(msg){}) receives progress lines;
    # a per-plugin exception is logged and skipped, never fatal. Shared by the
    # backend's poller thread and the `devmux plugins poll` debug command.
    def run_poll(registry, logger: ->(_m) {})
      list = pollable
      logger.call("poll cycle: #{list.map(&:id).inspect}")
      host = PluginHost.new(registry, logger: logger)
      list.each do |plugin|
        plugin.poll(host)
      rescue StandardError => e
        logger.call("#{plugin.id}: ERROR #{e.class}: #{e.message}")
      end
    end

    def disabled
      return [] unless File.exist?(store_path)
      data = JSON.parse(File.read(store_path))
      Array(data["disabled"]).map(&:to_s)
    rescue StandardError
      []
    end

    def save(list)
      FileUtils.mkdir_p(File.dirname(store_path))
      File.write(store_path, JSON.pretty_generate("disabled" => list.uniq))
    end

    # Where the enabled/disabled state lives. Mirrors TmuxSession.state_dir but
    # computed independently to keep this module free of that dependency (which
    # would otherwise be a require cycle: providers -> plugins -> tmux_session ->
    # registry -> context -> providers).
    def store_path
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux", "plugins.json")
    end
  end
end
