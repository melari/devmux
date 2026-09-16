require "io/console"
require "json"
require "fileutils"
require "devmux/projects"
require "devmux/icons"

module Devmux
  # The project picker: a small modal TUI launched in a centered tmux popup (the
  # "n" key — new session) listing the known projects (Devmux::Projects.list) with
  # the default floated to the top. Type to filter, j/k or the arrows move, Enter
  # picks the highlighted project (or, when nothing matches, the typed path if it's
  # a directory), Esc/Ctrl-c cancel.
  #
  # It's its own process, so it can't spawn the agent itself (that needs the
  # manager driving tmux); instead it writes the chosen path to the handoff file
  # (Projects.picked_path), which the manager reads after the popup closes.
  class ProjectPicker
    # How many rows of the (possibly long) list to show at once.
    VISIBLE = 12

    def initialize
      @all = ordered_projects
      @filter = +""
      @sel = 0
    end

    # The known projects with the default (what `n` used to open silently) floated
    # to the top, so it's the first, pre-selected choice.
    def ordered_projects
      list = Projects.list
      default = Projects.default
      return list unless default && list.include?(default)
      [default] + (list - [default])
    end

    def run
      IO.console.raw do
        render
        loop do
          key = next_key
          case key
          when :down then move(1)
          when :up   then move(-1)
          when "\r", "\n" then (choose; break)
          when "\e", "\u0003", "\u0004" then break # Esc / Ctrl-c / EOF
          when "\u007f", "\b" then backspace
          when String then type(key)
          end
          render
        end
      end
    rescue StandardError
      nil
    end

    private

    # Projects matching the current filter (case-insensitive substring on the
    # full path), or all when the filter is empty.
    def filtered
      return @all if @filter.empty?
      needle = @filter.downcase
      @all.select { |path| path.downcase.include?(needle) }
    end

    def move(delta)
      list = filtered
      return if list.empty?
      @sel = (@sel + delta).clamp(0, list.size - 1)
    end

    def backspace
      @filter.chop!
      @sel = 0
    end

    def type(key)
      return unless key.bytesize == 1 && (0x20..0x7e).cover?(key.ord)
      @filter << key
      @sel = 0
    end

    # Write the chosen project to the handoff file: the highlighted match, or —
    # when nothing matches — the typed filter if it expands to a real directory
    # (so you can jump to a repo the scan didn't surface). No file written on an
    # empty choice, so the manager treats it as a cancel.
    def choose
      path = filtered[@sel] || manual_path
      return unless path
      FileUtils.mkdir_p(File.dirname(Projects.picked_path))
      File.write(Projects.picked_path, JSON.generate("path" => path))
    rescue StandardError
      nil
    end

    def manual_path
      return nil if @filter.empty?
      expanded = File.expand_path(@filter)
      File.directory?(expanded) ? expanded : nil
    end

    def render
      list = filtered
      @sel = @sel.clamp(0, [list.size - 1, 0].max)
      lines = ["new agent in project", "", filter_line, ""]
      if list.empty?
        lines << dim(manual_path ? "↵ use #{tilde(manual_path)}" : "  (no matches)")
      else
        window(list).each { |i| lines << row(list[i], i == @sel) }
      end
      lines << ""
      lines << dim("[type] filter   [j/k] move   [enter] pick   [esc] cancel")
      draw(lines)
    end

    # The slice of list indices to show, scrolled to keep the selection visible.
    def window(list)
      return (0...list.size).to_a if list.size <= VISIBLE
      top = (@sel - VISIBLE / 2).clamp(0, list.size - VISIBLE)
      (top...(top + VISIBLE)).to_a
    end

    def filter_line
      shown = @filter.empty? ? dim("type to filter…") : @filter
      "  \e[38;5;208m▌\e[0m #{shown}"
    end

    # One project row: selection cursor, the repo's basename, then its parent path
    # dimmed (so basenames line up and the location is still visible). The cursor
    # is orange on the selected row to match the popup border.
    def row(path, selected)
      name = File.basename(path)
      parent = dim(tilde(File.dirname(path)))
      if selected
        "\e[38;5;208m#{Icons.selector} \e[0m#{name}  #{parent}"
      else
        "  #{name}  #{parent}"
      end
    end

    def tilde(path)
      home = Dir.home
      path.start_with?(home) ? path.sub(home, "~") : path
    end

    def dim(str)
      "\e[2;38;5;245m#{str}\e[0m"
    end

    def draw(lines)
      rows, cols = size
      top = [(rows - lines.size) / 2, 0].max
      $stdout.write("\e[H\e[2J")
      top.times { $stdout.write("\r\n") }
      lines.each { |line| $stdout.write(center(line, cols) + "\r\n") }
      $stdout.flush
    end

    def center(str, cols)
      visible = str.gsub(/\e\[[0-9;]*m/, "").length
      pad = [(cols - visible) / 2, 0].max
      (" " * pad) + str
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

    # Read one keypress (raw mode), decoding the up/down arrows. An unrecognized
    # escape sequence returns :ignore (a no-op) rather than "\e", so an arrow
    # variant doesn't close the picker.
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
      when "" then "\e" # lone Esc
      else :ignore
      end
    rescue IO::WaitReadable, EOFError, StandardError
      ""
    end
  end
end
