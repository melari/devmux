require "json"

module Devmux
  # The current git state of each session worktree — HEAD sha and whether it's
  # dirty — tracked centrally by the manager (see TmuxBackend#track_worktrees)
  # with `git --no-optional-locks` so it never contends with an agent's own git.
  # Refreshed frequently into a small JSON store ({ path => {"sha", "dirty"} });
  # plugins read it here — fresh, never cached — to compare local state against
  # remote without running git themselves.
  #
  # Computed independently of TmuxSession (mirrors PluginStore) so plugins don't
  # pull in the tmux stack.
  module Worktrees
    module_function

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def store_path
      File.join(state_dir, "worktrees.json")
    end

    # { worktree_path => { "sha" =>, "dirty" => } } for all tracked worktrees.
    def all
      return {} unless File.exist?(store_path)
      data = JSON.parse(File.read(store_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    # The tracked HEAD sha for a worktree path, or nil if unknown.
    def sha(path)
      rec = all[path.to_s]
      rec && rec["sha"]
    end

    # Whether the worktree has uncommitted changes (false if unknown).
    def dirty?(path)
      rec = all[path.to_s]
      rec ? !!rec["dirty"] : false
    end
  end
end
