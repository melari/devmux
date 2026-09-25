require "json"
require "yaml"
require "open3"
require "fileutils"
require "devmux/worktrees"
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
  #   context_keys             -> { key => spec } new context keys this plugin adds
  #   examples_for(key)        -> [String] example ids contributed for a context key
  #   resource_details(id)     -> { glyph:, color:, icons:, title:, annotation: }, or nil
  #   resource_url(id)         -> String browser URL for an identifier, or nil
  #   poll(host)               -> background sync (see Devmux::PluginHost)
  #   poll_interval            -> Integer  seconds between polls (default 30)
  #   actions(context)         -> [ { id:, label:, active_label:, command:[argv],
  #                                   icon:, name: } ] command actions for the
  #                                "m" menu; a background (long-running) toggle.
  #   action_indicator(id, ctx)-> { icon:, name:, color: } live indicator for a
  #                                running action (overrides the one captured at
  #                                start), so the title can reflect changing state.
  #
  # Enabled/disabled state persists as JSON under the state dir, read fresh on
  # every query (never cached): the plugins menu runs in a separate process (a
  # tmux popup) from the manager UI and the `devmux context` CLI, and all must
  # see each other's writes.
  module Plugins
    BUILTIN = [Github.new, Linear.new, Slack.new].freeze

    # Third-party plugins are git repos installed under `install_dir`, each with a
    # manifest at its root listing the plugin files/classes to load:
    #
    #   # .devmux-plugin.yml
    #   plugins:
    #     - { file: beta.rb, class: Devmux::Plugins::Beta }
    #
    # `devmux plugins install <git-url>` clones one; the manager updates them
    # (git fetch + ff) in the background, taking effect on the next launch (they're
    # loaded once, at first use). This mirrors how gitpack keeps devmux itself
    # updated. The plugin interface isn't a stable contract yet — pre-release.
    MANIFEST = ".devmux-plugin.yml".freeze

    module_function

    # Built-in plugins plus any installed third-party ones (loaded once, memoized).
    def all
      BUILTIN + external
    end

    def external
      @external ||= load_external
    end

    # Where installed plugin repos live (code, so under XDG_DATA_HOME, not state).
    def install_dir
      base = ENV["XDG_DATA_HOME"] || File.join(Dir.home, ".local", "share")
      File.join(base, "devmux", "plugins")
    end

    # Non-fatal per-plugin load errors, surfaced by `devmux plugins list`.
    def load_errors
      @load_errors ||= []
    end

    # Load every installed plugin repo's manifest and instantiate its classes.
    def load_external
      @load_errors = []
      return [] unless File.directory?(install_dir)
      Dir.children(install_dir).sort.flat_map { |name| load_repo(File.join(install_dir, name)) }
    rescue StandardError => e
      (@load_errors ||= []) << "load_external: #{e.class}: #{e.message}"
      []
    end

    def load_repo(repo)
      return [] unless File.directory?(repo)
      manifest = File.join(repo, MANIFEST)
      return [] unless File.exist?(manifest)
      # Put the repo on the load path so a plugin can require sibling files.
      $LOAD_PATH.unshift(repo) unless $LOAD_PATH.include?(repo)
      spec = YAML.safe_load(File.read(manifest))
      Array(spec && spec["plugins"]).filter_map { |entry| load_plugin_entry(repo, entry) }
    rescue StandardError => e
      load_errors << "#{File.basename(repo)}/#{MANIFEST}: #{e.class}: #{e.message}"
      []
    end

    def load_plugin_entry(repo, entry)
      file = entry && entry["file"]
      klass = entry && entry["class"]
      return nil unless file && klass
      require File.expand_path(file, repo)
      Object.const_get(klass).new
    rescue StandardError => e
      load_errors << "#{File.basename(repo)}/#{file}: #{e.class}: #{e.message}"
      nil
    end

    # Clone a plugin repo into install_dir. Validates it carries a manifest;
    # otherwise removes the clone. Takes effect on the next devmux launch.
    def install(git_url, logger: ->(m) { puts m })
      name = repo_name(git_url)
      return logger.call("could not derive a name from: #{git_url}") if name.empty?
      FileUtils.mkdir_p(install_dir)
      target = File.join(install_dir, name)
      return logger.call("already installed: #{name} (#{target})") if File.exist?(target)
      logger.call("cloning #{git_url} …")
      unless system("git", "clone", "--quiet", git_url, target)
        logger.call("clone failed")
        return
      end
      unless File.exist?(File.join(target, MANIFEST))
        FileUtils.rm_rf(target)
        return logger.call("not a devmux plugin repo (missing #{MANIFEST})")
      end
      logger.call("installed #{name}; restart devmux to load it")
    end

    # Update every installed plugin repo (git fetch + fast-forward), like gitpack.
    # Called from the manager in the background; updates apply on the next launch.
    def update_external!(logger: ->(_m) {})
      return unless File.directory?(install_dir)
      Dir.children(install_dir).each do |name|
        repo = File.join(install_dir, name)
        update_repo(repo, name, logger) if File.directory?(File.join(repo, ".git"))
      end
    end

    def update_repo(repo, name, logger)
      system("git", "-C", repo, "fetch", "--quiet", out: File::NULL, err: File::NULL)
      local, = Open3.capture2("git", "-C", repo, "rev-parse", "HEAD")
      remote, status = Open3.capture2("git", "-C", repo, "rev-parse", "@{u}")
      return unless status.success?
      return if local.strip == remote.strip
      if system("git", "-C", repo, "merge", "--ff-only", "--quiet", out: File::NULL, err: File::NULL)
        logger.call("plugins: updated #{name} (restart to load)")
      else
        logger.call("plugins: #{name} has diverged from upstream; skipped")
      end
    rescue StandardError => e
      logger.call("plugins: #{name} update error: #{e.class}: #{e.message}")
    end

    def repo_name(git_url)
      File.basename(git_url.to_s.strip.sub(%r{/\z}, "").sub(/\.git\z/, ""))
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

    # Command actions available for a session context, across enabled plugins,
    # each tagged with its owning plugin's id. Consumed by the "m" actions menu.
    def actions(context)
      enabled.select { |p| p.respond_to?(:actions) }.flat_map do |plugin|
        Array(plugin.actions(context)).map { |a| a.merge(plugin_id: plugin.id) }
      end
    rescue StandardError
      []
    end

    # A live indicator ({ icon:, name:, color: }) for a running action from its
    # owning plugin, or nil — lets the running-process title reflect changing state
    # (e.g. the beta's current deployed SHA) rather than the value captured when it
    # started.
    def action_indicator(plugin_id, action_id, context)
      plugin = find(plugin_id)
      return nil unless plugin && plugin.respond_to?(:action_indicator)
      plugin.action_indicator(action_id, context)
    rescue StandardError
      nil
    end

    # Run one poll cycle: every enabled pollable plugin's `poll`, handed a
    # PluginHost over `registry`. `logger` (a ->(msg){}) receives progress lines;
    # a per-plugin exception is logged and skipped, never fatal. Used by the
    # one-shot `devmux plugins poll` debug command (the manager uses per-plugin
    # poller threads that call poll_one directly).
    def run_poll(registry, logger: ->(_m) {})
      list = pollable
      logger.call("poll cycle: #{list.map(&:id).inspect}")
      list.each { |plugin| poll_one(plugin, registry, logger: logger) }
    end

    # Run a single plugin's `poll` with a fresh PluginHost, logging (never
    # raising) on error. `running` is the current background-action snapshot the
    # host exposes so a plugin can react to its own running actions. The unit the
    # per-plugin poller threads call.
    def poll_one(plugin, registry, logger: ->(_m) {}, running: [])
      plugin.poll(PluginHost.new(registry, logger: logger, running: running))
    rescue StandardError => e
      logger.call("#{plugin.id}: ERROR #{e.class}: #{e.message}")
    end

    # A plugin's poll cadence in seconds — its `poll_interval` if it defines one,
    # else `default`. Lets a slow plugin (e.g. beta's `beta ls`) poll less often on
    # its own thread without holding up the others.
    def poll_interval(plugin, default:)
      return default unless plugin.respond_to?(:poll_interval)
      value = plugin.poll_interval.to_i
      value.positive? ? value : default
    end

    def disabled
      stat = File.stat(store_path)
      key = [stat.mtime, stat.size, stat.ino]
      cached = @disabled_cache
      return cached[1].dup if cached && cached[0] == key
      list = Array(JSON.parse(File.read(store_path))["disabled"]).map(&:to_s).freeze
      @disabled_cache = [key, list]
      list.dup
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
