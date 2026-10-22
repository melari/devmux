require "json"
require "fileutils"
require "securerandom"

module Devmux
  module Tasks
    module_function

    DEFAULT_HOURS = [9 * 60, 17 * 60].freeze

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def store_path
      File.join(state_dir, "tasks.json")
    end

    def picked_path
      File.join(state_dir, "picked-task.json")
    end

    def all
      return [] unless File.exist?(store_path)
      data = JSON.parse(File.read(store_path))
      Array(data.is_a?(Hash) ? data["tasks"] : data).select { |t| t.is_a?(Hash) && t["id"] }
    rescue StandardError
      []
    end

    def find(id)
      all.find { |t| t["id"] == id }
    end

    def add(attrs)
      task = { "id" => SecureRandom.hex(4), "hours_start" => DEFAULT_HOURS[0],
               "hours_end" => DEFAULT_HOURS[1] }.merge(attrs)
      save(all + [task])
      task
    end

    def update(id, attrs)
      save(all.map { |t| t["id"] == id ? t.merge(attrs) : t })
    end

    def remove(id)
      save(all.reject { |t| t["id"] == id })
    end

    def mark_run(id, time = Time.now)
      update(id, "last_run" => time.to_i)
    end

    def scheduled?(task)
      task["interval"].to_i.positive?
    end

    def in_hours?(task, time = Time.now)
      start = task["hours_start"] || DEFAULT_HOURS[0]
      finish = task["hours_end"] || DEFAULT_HOURS[1]
      now = (time.hour * 60) + time.min
      start <= finish ? now >= start && now < finish : now >= start || now < finish
    end

    def due?(task, time = Time.now)
      return false unless scheduled?(task) && in_hours?(task, time)
      last = task["last_run"].to_i
      last.zero? || time.to_i - last >= task["interval"].to_i * 60
    end

    def parse_time(str)
      m = str.to_s.strip.match(/\A(\d{1,2})(?::(\d{2}))?\z/)
      return nil unless m
      hour = m[1].to_i
      minute = m[2].to_i
      return nil if hour > 24 || minute > 59 || (hour == 24 && minute.positive?)
      (hour * 60) + minute
    end

    def format_time(minutes)
      format("%<h>02d:%<m>02d", h: minutes.to_i / 60, m: minutes.to_i % 60)
    end

    def schedule_label(task)
      return "manual" unless scheduled?(task)
      "every #{task['interval']}m, #{format_time(task['hours_start'])}-#{format_time(task['hours_end'])}"
    end

    def save(list)
      FileUtils.mkdir_p(state_dir)
      tmp = "#{store_path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate("tasks" => list))
      File.rename(tmp, store_path)
    end
  end
end
