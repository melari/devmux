require "json"
require "fileutils"
require "securerandom"
require "devmux/context"

module Devmux
  # Persistent map of devmux agents: name (stable slug), Claude session UUID,
  # archived flag, and a generic context hash (see Devmux::Context). Hiding an
  # agent kills its pane (Claude has saved the conversation); showing it resumes.
  # Archiving sets it aside; deleting drops the record. The registry reconnects a
  # name/UUID to its Claude session across all of these and across restarts.
  #
  # It's stored as JSON under the state dir and read/written fresh on every call
  # rather than cached: the `devmux context` CLI runs in a *separate* process
  # from the manager UI, and both mutate this file, so a cached copy would let
  # one clobber the other's writes.
  class Registry
    def initialize(path)
      @path = path
      # Guards read-modify-write against the plugin poller thread mutating the
      # same file concurrently with the UI thread. Non-reentrant, so no public
      # method here may call another.
      @mutex = Mutex.new
    end

    # [{ "name", "uuid", "archived", "context" }] in insertion order.
    def agents
      @mutex.synchronize { load }
    end

    def names
      @mutex.synchronize { load.map { |a| a["name"] } }
    end

    def uuid_for(name)
      @mutex.synchronize do
        rec = by_name(load, name)
        rec && rec["uuid"]
      end
    end

    # Look up a record by UUID or name (the CLI accepts either as a session id).
    def record(id)
      @mutex.synchronize { by_id(load, id) }
    end

    # `project` (optional) is the directory the agent runs in — its pane's cwd.
    # Stored on the record so it survives hide/show and restarts; nil means "use
    # the default project" (see TmuxBackend#agent_cwd).
    def add(project: nil)
      @mutex.synchronize do
        data = load
        rec = { "name" => next_name(data), "uuid" => SecureRandom.uuid,
                "archived" => false, "context" => {} }
        rec["project"] = project unless project.to_s.empty?
        data << rec
        save(data)
        rec
      end
    end

    # Reorder an active session by one step (delta -1 up / +1 down) through the
    # grouped sidebar order. `group_ids` is the full group order INCLUDING the
    # implicit unnamed group "" at the front. Within a group it swaps with its
    # neighbour; at a group's edge it crosses into the adjacent group (becoming
    # that group's first/last member) — which is how a session changes group.
    # Groups in `skip` (collapsed in the sidebar) are stepped over, never entered.
    # No-op at the very top/bottom. All position math happens here under the mutex.
    def move(name, delta, group_ids, skip: [])
      @mutex.synchronize do
        data = load
        rec = by_name(data, name)
        next if rec.nil? || rec["archived"]
        active = data.reject { |a| a["archived"] }
        cur = group_of(rec, group_ids)
        peers = active.select { |a| group_of(a, group_ids) == cur }
        idx = peers.index(rec)
        if delta.positive?
          idx < peers.size - 1 ? swap_positions(data, rec, peers[idx + 1]) : cross_group(data, rec, cur, group_ids, +1, skip)
        else
          idx.positive? ? swap_positions(data, rec, peers[idx - 1]) : cross_group(data, rec, cur, group_ids, -1, skip)
        end
        save(data)
      end
    end

    # Set (or clear, when blank) a session's group id.
    def set_group(name, group_id)
      @mutex.synchronize do
        data = load
        rec = by_name(data, name)
        next unless rec
        group_id.to_s.empty? ? rec.delete("group") : rec["group"] = group_id
        save(data)
      end
    end

    def set_archived(name, value)
      @mutex.synchronize do
        data = load
        rec = by_name(data, name)
        next unless rec
        rec["archived"] = value
        save(data)
      end
    end

    def delete(name)
      @mutex.synchronize do
        data = load
        data.reject! { |a| a["name"] == name }
        save(data)
      end
    end

    # A session's context (by UUID or name) with schema defaults applied, or nil
    # if there's no such session.
    def context(id)
      @mutex.synchronize do
        rec = by_id(load, id)
        rec && Context.with_defaults(rec["context"], rec)
      end
    end

    # Write one context key; returns the record (for callers that need its slug)
    # or nil if the session doesn't exist.
    def write_context(id, key, value)
      @mutex.synchronize do
        data = load
        rec = by_id(data, id)
        next nil unless rec
        (rec["context"] ||= {})[key] = value
        save(data)
        rec
      end
    end

    private

    # A record's group id, normalized to "" (unnamed) when unset or pointing at a
    # group that no longer exists.
    def group_of(rec, group_ids)
      gid = rec["group"].to_s
      group_ids.include?(gid) ? gid : ""
    end

    # Swap two records' positions in the array (they share a group, so this just
    # flips their relative order).
    def swap_positions(data, first, second)
      i = data.index(first)
      j = data.index(second)
      data[i], data[j] = data[j], data[i] if i && j
    end

    # Move `rec` into the adjacent group (dir +1 down / -1 up), reassigning its
    # group and repositioning it so it renders first (moving down) or last (moving
    # up) of that group, passing over any `skip` groups. No-op past the
    # first/last group.
    def cross_group(data, rec, cur, group_ids, dir, skip = [])
      ci = group_ids.index(cur)
      ti = ci && ci + dir
      ti += dir while ti && ti.between?(0, group_ids.size - 1) && skip.include?(group_ids[ti])
      return if ti.nil? || ti.negative? || ti >= group_ids.size
      target = group_ids[ti]
      target.empty? ? rec.delete("group") : rec["group"] = target
      data.delete(rec)
      if dir.positive?
        at = data.index { |a| group_of(a, group_ids) == target }
        at ? data.insert(at, rec) : data.push(rec)
      else
        last = last_index(data) { |a| group_of(a, group_ids) == target }
        last ? data.insert(last + 1, rec) : data.push(rec)
      end
    end

    def last_index(data)
      found = nil
      data.each_with_index { |a, i| found = i if yield(a) }
      found
    end

    def by_name(data, name)
      data.find { |a| a["name"] == name }
    end

    def by_id(data, id)
      data.find { |a| a["uuid"] == id } || data.find { |a| a["name"] == id }
    end

    def next_name(data)
      used = data.map { |a| a["name"][/\d+/].to_i }
      "agent-#{(used.max || 0) + 1}"
    end

    def load
      return [] unless File.exist?(@path)
      data = JSON.parse(File.read(@path))
      data.is_a?(Array) ? data : []
    rescue StandardError
      []
    end

    # Persist atomically (temp + rename) so a concurrent reader — the poller
    # thread, or the separate `devmux context` process — never sees a torn file.
    # Deliberately NOT rescued: a failed write (e.g. a sandboxed agent that can't
    # write the state dir) must surface, not silently no-op.
    def save(data)
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, @path)
    end
  end
end
