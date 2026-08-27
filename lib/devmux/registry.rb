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

    def add
      @mutex.synchronize do
        data = load
        rec = { "name" => next_name(data), "uuid" => SecureRandom.uuid,
                "archived" => false, "context" => {} }
        data << rec
        save(data)
        rec
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
