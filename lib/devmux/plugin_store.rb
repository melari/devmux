require "json"
require "fileutils"

module Devmux
  # A small disk-backed JSON store a plugin owns, for whatever state it needs to
  # persist between polls (e.g. the github plugin caches each PR's open/merged/
  # closed state, and which PRs it has already spun sessions up for).
  #
  # Read fresh on every call and written atomically (temp + rename), so the
  # background poller thread and the manager UI can both touch it without seeing
  # a torn file. Each plugin gets its own file, keyed by id.
  class PluginStore
    def initialize(id)
      @id = id
    end

    def read
      return {} unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write(hash)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(hash))
      File.rename(tmp, path)
    end

    def mtime
      File.mtime(path)
    rescue StandardError
      nil
    end

    # Mirrors TmuxSession.state_dir but computed independently (see the note in
    # Plugins.store_path — plugins must not require the tmux stack).
    def path
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux", "plugin-#{@id}.json")
    end
  end
end
