require "json"
require "fileutils"
require "securerandom"

module Devmux
  # Named groups for organizing sessions in the sidebar. A group is just an id +
  # a display name (which may include emoji); the *order* of the stored list is
  # the order groups render in. There's also an implicit "unnamed" group (id "")
  # that always sits at the top with no header — sessions live there by default.
  #
  # A session's membership is a `group` id on its registry record (see Registry);
  # a session pointing at a since-deleted group falls back to unnamed. Groups are
  # created/removed from the settings popup, which is a separate process, so this
  # store is read fresh on every query (never cached), mirroring Plugins.
  module Groups
    module_function

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def store_path
      File.join(state_dir, "groups.json")
    end

    # [{ id:, name: }] in display order.
    def all
      return [] unless File.exist?(store_path)
      data = JSON.parse(File.read(store_path))
      arr = data.is_a?(Hash) ? data["groups"] : data
      Array(arr).map { |g| { id: g["id"].to_s, name: g["name"].to_s } }
                .reject { |g| g[:id].empty? }
    rescue StandardError
      []
    end

    # Ids in display order (excludes the implicit unnamed "").
    def ids
      all.map { |g| g[:id] }
    end

    def id?(id)
      ids.include?(id.to_s)
    end

    def name(id)
      group = all.find { |g| g[:id] == id.to_s }
      group && group[:name]
    end

    # Create a group with the given name (appended to the end). No-op on a blank
    # name. Returns the new group's id (or nil).
    def add(name)
      name = name.to_s.strip
      return nil if name.empty?
      list = all
      id = SecureRandom.hex(4)
      list << { id: id, name: name }
      save(list)
      id
    end

    def remove(id)
      save(all.reject { |g| g[:id] == id.to_s })
    end

    # Reorder a group one step (delta -1 up / +1 down) in the display order.
    # No-op at the ends. Returns the group's new index, or nil.
    def move(id, delta)
      list = all
      i = list.index { |g| g[:id] == id.to_s }
      return nil unless i
      j = i + delta
      return nil if j.negative? || j >= list.size
      list[i], list[j] = list[j], list[i]
      save(list)
      j
    end

    def rename(id, name)
      name = name.to_s.strip
      return if name.empty?
      save(all.map { |g| g[:id] == id.to_s ? { id: g[:id], name: name } : g })
    end

    def save(list)
      FileUtils.mkdir_p(File.dirname(store_path))
      serialized = list.map { |g| { "id" => g[:id], "name" => g[:name] } }
      File.write(store_path, JSON.pretty_generate("groups" => serialized))
    end
  end
end
