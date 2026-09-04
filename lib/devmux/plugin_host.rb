module Devmux
  # The slice of devmux a plugin's `poll` is handed. It deliberately hides the
  # registry internals behind a small, stable API so a third-party plugin only
  # depends on this surface:
  #
  #   host.sessions
  #     -> [{ name:, prs: [ids], tickets: [ids], worktree:, context:,
  #           background: [{plugin_id:, action_id:}] }, ...] for every session, so
  #        the plugin can tell which resources are attached, refresh their state,
  #        compare against local (worktree/context), and see which of its own
  #        background actions are currently running (background).
  #   host.log(message)
  #     -> record a line of plugin activity (goes to the plugin log in the
  #        background poller; also echoed to stdout under `devmux plugins poll`).
  #
  # A poll is read-only with respect to sessions: it can inspect what's attached
  # and cache resource state, but it cannot create or modify sessions. It wraps a
  # Registry, whose reads are mutex-guarded, so calling this from the poller
  # thread is safe against the UI thread.
  class PluginHost
    def initialize(registry, logger: nil, running: [])
      @registry = registry
      @logger = logger
      # Currently-running plugin background actions: [{uuid:, plugin_id:, action_id:}].
      @running = running || []
    end

    def log(message)
      @logger&.call(message)
    end

    def sessions
      @registry.agents.map do |a|
        ctx = a["context"] || {}
        { name: a["name"], prs: Array(ctx["prs"]), tickets: Array(ctx["tickets"]),
          worktree: ctx["worktree"], context: ctx,
          background: @running.select { |r| r[:uuid] == a["uuid"] }
                              .map { |r| { plugin_id: r[:plugin_id], action_id: r[:action_id] } } }
      end
    end
  end
end
