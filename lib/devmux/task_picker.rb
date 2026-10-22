require "io/console"
require "json"
require "fileutils"
require "devmux/tasks"
require "devmux/icons"

module Devmux
  class TaskPicker
    def initialize
      @tasks = Tasks.all
      @sel = 0
    end

    def run
      IO.console.raw do
        render
        loop do
          case next_key
          when "j", :down then move(1)
          when "k", :up   then move(-1)
          when "\r", "\n" then (choose; break)
          when "\e", "q", "\u0003", "\u0004" then break
          end
          render
        end
      end
    rescue StandardError
      nil
    end

    private

    def move(delta)
      return if @tasks.empty?
      @sel = (@sel + delta).clamp(0, @tasks.size - 1)
    end

    def choose
      task = @tasks[@sel]
      return unless task
      FileUtils.mkdir_p(File.dirname(Tasks.picked_path))
      File.write(Tasks.picked_path, JSON.generate("id" => task["id"]))
    rescue StandardError
      nil
    end

    def render
      lines = ["run a background task", ""]
      if @tasks.empty?
        lines << dim("  (no tasks yet; add one in settings › tasks)")
      else
        @tasks.each_with_index { |task, i| lines << row(task, i == @sel) }
      end
      lines << ""
      lines << dim("[j/k] move   [enter] run   [esc] cancel")
      draw(lines)
    end

    def row(task, selected)
      label = "#{task['name']}  #{dim(Tasks.schedule_label(task))}"
      selected ? "\e[38;5;208m#{Icons.selector} \e[0m#{label}" : "  #{label}"
    end

    def dim(str)
      "\e[2;38;5;245m#{str}\e[0m"
    end

    def draw(lines)
      rows, cols = size
      width = lines.map { |line| line.gsub(/\e\[[0-9;]*m/, "").length }.max || 0
      left = " " * [(cols - width) / 2, 0].max
      top = [(rows - lines.size) / 2, 0].max
      $stdout.write("\e[H\e[2J")
      top.times { $stdout.write("\r\n") }
      lines.each { |line| $stdout.write(left + line + "\r\n") }
      $stdout.flush
    end

    def size
      IO.console.winsize
    rescue StandardError
      [22, 64]
    end

    def next_key
      IO.select([$stdin])
      read_key
    rescue StandardError
      ""
    end

    def read_key
      ch = $stdin.read_nonblock(1)
      return ch unless ch == "\e"
      seq = +""
      2.times do
        byte = begin
          $stdin.read_nonblock(1)
        rescue IO::WaitReadable, EOFError
          nil
        end
        break unless byte
        seq << byte
      end
      case seq
      when "[A" then :up
      when "[B" then :down
      when "" then "\e"
      else :ignore
      end
    rescue IO::WaitReadable, EOFError, StandardError
      ""
    end
  end
end
