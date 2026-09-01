require "json"
require "fileutils"

module Devmux
  # The set of directories agents can run in — a devmux "project" is just a repo
  # root. New agents default to `default` (seeded from the first launch dir), but
  # pressing N opens the picker to start one in any known project instead. Each
  # agent records its chosen project (see Registry#add), which drives its pane's
  # cwd — so the directory devmux itself was launched from stops mattering.
  #
  # State lives as JSON under the state dir, read fresh on every query (never
  # cached): the picker runs in a separate process (a tmux popup) from the
  # manager, so both must see each other's writes. Its state_dir is computed
  # independently of TmuxSession to avoid a require cycle (mirrors Plugins).
  module Projects
    # Where to look for repos when none are configured. Each root is scanned for
    # directories containing a `.git`, up to SCAN_DEPTH deep.
    DEFAULT_ROOTS = ["~/src"].freeze
    SCAN_DEPTH = 3

    module_function

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def config_path
      File.join(state_dir, "projects.json")
    end

    # The handoff file the picker writes its choice to and the manager reads back
    # after the popup closes (see TmuxBackend#new_agent_pick).
    def picked_path
      File.join(state_dir, "picked-project.json")
    end

    def config
      return {} unless File.exist?(config_path)
      data = JSON.parse(File.read(config_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def save(cfg)
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, JSON.pretty_generate(cfg))
    end

    # The default project new agents open in, or nil if unset.
    def default
      value = config["default"].to_s
      value.empty? ? nil : value
    end

    # Record the default project. Seeded from the launch dir on first run (see
    # TmuxSession.launch!); only ever set when unset, so the *first* launch dir
    # becomes the durable default and later launches from elsewhere don't move it.
    def set_default(path)
      return if path.to_s.empty?
      cfg = config
      return if cfg["default"].to_s == path
      cfg["default"] = path
      save(cfg)
    end

    # Directories to scan for repos: configured `roots`, else DEFAULT_ROOTS.
    def roots
      list = Array(config["roots"]).map { |r| File.expand_path(r) }
      list = DEFAULT_ROOTS.map { |r| File.expand_path(r) } if list.empty?
      list.select { |dir| File.directory?(dir) }
    end

    # All known project dirs: git repos found under the roots, plus the default
    # and any manually pinned `extra` paths. Deduped to existing dirs, sorted by
    # basename. Only called from the picker (on N), so the scan cost is off the
    # hot path.
    def list
      found = roots.flat_map { |root| scan(root) }
      pinned = Array(config["extra"]).map { |p| File.expand_path(p) }
      ([default] + found + pinned).compact.uniq
        .select { |dir| File.directory?(dir) }
        .sort_by { |dir| File.basename(dir).downcase }
    end

    # Git repos under `root` (a directory containing a `.git`), recursing into
    # non-repo subdirectories up to `depth`. A repo isn't descended into (no
    # nested worktrees in the picker). Best-effort; unreadable dirs are skipped.
    def scan(root, depth = SCAN_DEPTH)
      return [] if depth <= 0
      Dir.children(root).each_with_object([]) do |child, repos|
        dir = File.join(root, child)
        next unless File.directory?(dir)
        if File.exist?(File.join(dir, ".git"))
          repos << dir
        else
          repos.concat(scan(dir, depth - 1))
        end
      end
    rescue StandardError
      []
    end
  end
end
