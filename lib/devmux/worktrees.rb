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

    def head(path)
      gitdir = git_dir(path.to_s)
      return nil unless gitdir
      ref = File.read(File.join(gitdir, "HEAD")).strip
      return { "sha" => ref, "branch" => nil } unless ref.start_with?("ref: ")
      name = ref.delete_prefix("ref: ")
      sha = resolve_ref(gitdir, common_dir(gitdir), name)
      sha && { "sha" => sha, "branch" => name.delete_prefix("refs/heads/") }
    rescue StandardError
      nil
    end

    def git_dir(path)
      dotgit = File.join(path, ".git")
      return dotgit if File.directory?(dotgit)
      return nil unless File.file?(dotgit)
      pointer = File.read(dotgit)[/\Agitdir: (.+)$/, 1]
      pointer && File.expand_path(pointer.strip, path)
    end

    def common_dir(gitdir)
      file = File.join(gitdir, "commondir")
      File.file?(file) ? File.expand_path(File.read(file).strip, gitdir) : gitdir
    end

    def resolve_ref(gitdir, common, name, depth = 0)
      return nil if depth > 4
      [gitdir, common].uniq.each do |dir|
        loose = File.join(dir, name)
        next unless File.file?(loose)
        value = File.read(loose).strip
        return value unless value.start_with?("ref: ")
        return resolve_ref(gitdir, common, value.delete_prefix("ref: "), depth + 1)
      end
      packed = File.join(common, "packed-refs")
      return nil unless File.file?(packed)
      File.foreach(packed) do |line|
        sha, ref = line.split(" ", 2)
        return sha if ref && ref.strip == name
      end
      nil
    end
  end
end
