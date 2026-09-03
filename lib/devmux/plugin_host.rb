module Devmux
  # The slice of devmux a plugin's `poll` is handed. It deliberately hides the
  # registry internals behind a small, stable API so a third-party plugin only
  # depends on this surface:
  #
  #   host.sessions
  #     -> [{ name:, prs: [ids], tickets: [ids] }, ...] for every session, so the
  #        plugin can tell which resources are attached and refresh their state.
  #   host.log(message)
  #     -> record a line of plugin activity (goes to the plugin log in the
  #        background poller; also echoed to stdout under `devmux plugins poll`).
  #
  # A poll is read-only with respect to sessions: it can inspect what's attached
  # and cache resource state, but it cannot create or modify sessions. It wraps a
  # Registry, whose reads are mutex-guarded, so calling this from the poller
  # thread is safe against the UI thread.
  class PluginHost
    def initialize(registry, logger: nil)
      @registry = registry
      @logger = logger
    end

    def log(message)
      @logger&.call(message)
    end

    def sessions
      @registry.agents.map do |a|
        ctx = a["context"] || {}
        { name: a["name"], prs: Array(ctx["prs"]), tickets: Array(ctx["tickets"]) }
      end
    end
  end
end
