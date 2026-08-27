module Devmux
  # The slice of devmux a plugin's `poll` is handed. It deliberately hides the
  # registry internals behind a small, stable API so a third-party plugin only
  # depends on this surface:
  #
  #   host.sessions
  #     -> [{ name:, prs: [ids], tickets: [ids] }, ...] for every session, so the
  #        plugin can tell which resources are already attached to something.
  #   host.create_session(name:, prs:, tickets:)
  #     -> add a new (hidden) session with those resources attached.
  #   host.log(message)
  #     -> record a line of plugin activity (goes to the plugin log in the
  #        background poller; also echoed to stdout under `devmux plugins poll`).
  #
  # It wraps a Registry, whose reads/writes are mutex-guarded, so calling this
  # from the poller thread is safe against the UI thread.
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

    def create_session(name: nil, prs: [], tickets: [])
      rec = @registry.add
      id = rec["uuid"]
      @registry.write_context(id, "name", name) if name && !name.to_s.empty?
      @registry.write_context(id, "prs", Array(prs)) unless Array(prs).empty?
      @registry.write_context(id, "tickets", Array(tickets)) unless Array(tickets).empty?
      rec
    end
  end
end
