require "io/console"
require "devmux/plugins"
require "devmux/groups"
require "devmux/icons"

module Devmux
  # The settings popover: a small modal TUI launched in a centered tmux popup
  # (see UI's "z" key). It's a tiny two-level menu — a root list of categories,
  # each opening its own view:
  #
  #   Plugins — toggle each devmux plugin on/off (was the standalone plugins menu).
  #   Groups  — create / rename / remove the named sidebar groups.
  #
  # It runs as its own process, so it just reads and writes the shared Plugins /
  # Groups stores; the manager UI re-renders when it regains control after the
  # popup closes. Esc backs out of a category to the root, then closes the popup.
  class SettingsMenu
    CATEGORIES = %w[Groups Plugins].freeze

    def initialize
      @view = :root
      @sel = 0
    end

    def run
      IO.console.raw do
        render
        loop do
          break unless dispatch(next_key)
          render
        end
      end
    rescue StandardError
      nil
    end

    private

    # Route a key to the current view. Returns false to close the popup.
    def dispatch(key)
      case @view
      when :root    then root_key(key)
      when :plugins then plugins_key(key)
      when :groups  then groups_key(key)
      end
    end

    def root_key(key)
      case key
      when "j", :down then move(1, CATEGORIES.size)
      when "k", :up   then move(-1, CATEGORIES.size)
      when "\r", "\n" then open_category
      when "q", "\e" then return false
      end
      true
    end

    def open_category
      @view = CATEGORIES[@sel] == "Plugins" ? :plugins : :groups
      @sel = 0
    end

    def plugins_key(key)
      case key
      when "j", :down then move(1, Plugins.all.size)
      when "k", :up   then move(-1, Plugins.all.size)
      when "\r", "\n" then toggle_plugin
      when "\e", "q" then back_to_root
      end
      true
    end

    def toggle_plugin
      plugin = Plugins.all[@sel]
      Plugins.toggle(plugin.id) if plugin
    end

    def groups_key(key)
      case key
      when "j", :down then move(1, Groups.all.size)
      when "k", :up   then move(-1, Groups.all.size)
      when "J"      then reorder_group(1)
      when "K"      then reorder_group(-1)
      when "a", "n" then add_group
      when "d"      then delete_group
      when "r"      then rename_group
      when "\e", "q" then back_to_root
      end
      true
    end

    # Shift-J/Shift-K: move the highlighted group up/down in the display order,
    # keeping the cursor on it.
    def reorder_group(delta)
      group = Groups.all[@sel]
      return unless group
      moved = Groups.move(group[:id], delta)
      @sel = moved if moved
    end

    def add_group
      name = prompt("New group name:")
      Groups.add(name) if name && !name.strip.empty?
    end

    def delete_group
      group = Groups.all[@sel]
      Groups.remove(group[:id]) if group
      @sel = [@sel, [Groups.all.size - 1, 0].max].min
    end

    def rename_group
      group = Groups.all[@sel]
      return unless group
      name = prompt("Rename to:", group[:name])
      Groups.rename(group[:id], name) if name && !name.strip.empty?
    end

    def back_to_root
      @view = :root
      @sel = 0
    end

    def move(delta, size)
      return if size.zero?
      @sel = (@sel + delta).clamp(0, size - 1)
    end

    # ---- rendering ----

    def render
      case @view
      when :root    then render_root
      when :plugins then render_plugins
      when :groups  then render_groups
      end
    end

    def render_root
      lines = ["devmux settings", ""]
      CATEGORIES.each_with_index { |cat, i| lines << category_row(cat, i == @sel) }
      lines << ""
      lines << dim("[j/k] move   [↵] open   [q] close")
      draw(lines)
    end

    def category_row(name, selected)
      cursor = selected ? "#{Icons.selector} " : "  "
      selected ? "#{cursor}#{name}" : dim("#{cursor}#{name}")
    end

    def render_plugins
      lines = ["settings › plugins", ""]
      Plugins.all.each_with_index { |plugin, i| lines << plugin_row(plugin, i == @sel) }
      lines << ""
      lines << dim("[j/k] move   [↵] toggle   [esc] back")
      draw(lines)
    end

    def plugin_row(plugin, selected)
      cursor = selected ? "#{Icons.selector} " : "  "
      on = Plugins.enabled?(plugin.id)
      box = on ? Icons::CHECK_ON : Icons::CHECK_OFF
      logo = plugin.logo && Icons.nerd? ? "#{plugin.logo} " : ""
      text = "#{cursor}#{box} #{logo}#{plugin.name}"
      on ? text : dim(text)
    end

    def render_groups
      groups = Groups.all
      lines = ["settings › groups", ""]
      if groups.empty?
        lines << dim("  (no groups yet)")
      else
        groups.each_with_index { |group, i| lines << group_row(group, i == @sel) }
      end
      lines << ""
      lines << dim("[a] add   [r] rename   [J/K] reorder   [d] delete   [esc] back")
      draw(lines)
    end

    def group_row(group, selected)
      cursor = selected ? "#{Icons.selector} " : "  "
      text = "#{cursor}#{group[:name]}"
      selected ? text : dim(text)
    end

    def dim(str)
      "\e[2m#{str}\e[0m"
    end

    # Draw the block centered in the popup (both axes). The whole block shares one
    # left margin (computed from the widest line) and every line is left-aligned to
    # it — so selecting an item, which changes only that line's width, never shifts
    # it horizontally (centering each line independently would).
    def draw(lines)
      rows, cols = size
      width = lines.map { |line| display_width(strip_ansi(line)) }.max || 0
      left = " " * [(cols - width) / 2, 0].max
      top = [(rows - lines.size) / 2, 0].max
      $stdout.write("\e[H\e[2J")
      top.times { $stdout.write("\r\n") }
      lines.each { |line| $stdout.write(left + line + "\r\n") }
      $stdout.flush
    end

    def strip_ansi(str)
      str.gsub(/\e\[[0-9;]*m/, "")
    end

    # Approximate on-screen width, counting emoji / wide graphemes as 2 cells so
    # centering doesn't drift on group names with emoji.
    def display_width(str)
      graphemes(str).sum { |g| g.bytesize > 1 ? 2 : 1 }
    end

    def graphemes(str)
      str.scan(/\X/)
    rescue StandardError
      str.chars
    end

    def size
      IO.console.winsize
    rescue StandardError
      [22, 64]
    end

    # ---- text prompt (for group names; accepts emoji / multibyte) ----

    # A one-line modal editor centered in the popup. Enter commits (returns the
    # string), Esc cancels (returns nil), Backspace deletes a grapheme. Printable
    # input — including multibyte emoji arriving as one cluster — is appended.
    def prompt(title, initial = "")
      buffer = +initial.to_s
      loop do
        draw([title, "", "  \e[38;5;208m▌\e[0m #{buffer}▏", "", dim("[↵] save   [esc] cancel")])
        key = next_key
        case key
        when "\r", "\n" then return buffer
        when "\e" then return nil
        when "", "\b" then buffer = drop_grapheme(buffer)
        when String then buffer << key if printable?(key)
        end
      end
    end

    def drop_grapheme(str)
      graphemes(str)[0...-1].join
    end

    # Accept normal typed text and multibyte clusters (emoji), but not lone
    # control bytes.
    def printable?(str)
      return false if str.empty?
      str.bytesize > 1 || (0x20..0x7e).cover?(str.ord)
    end

    def next_key
      IO.select([$stdin])
      read_key
    rescue StandardError
      ""
    end

    # Read one keypress in raw mode. Arrows decode to :up/:down; a lone Esc is
    # "\e"; control bytes come back as single-char strings. A printable byte is
    # returned together with any bytes queued right behind it (read_nonblock until
    # it would block), so a pasted or IME-composed multibyte grapheme (emoji)
    # arrives as one String rather than split across reads.
    def read_key
      ch = $stdin.read_nonblock(1)
      return decode_escape if ch == "\e"
      return ch if ch.bytes.first < 0x20 || ch.bytes.first == 0x7f
      (ch + drain).force_encoding("UTF-8")
    rescue IO::WaitReadable, EOFError, StandardError
      ""
    end

    def drain
      buf = +""
      loop { buf << $stdin.read_nonblock(1) }
    rescue IO::WaitReadable, EOFError
      buf
    end

    def decode_escape
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
    end
  end
end
