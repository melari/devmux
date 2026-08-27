require "io/console"
require "devmux/plugins"
require "devmux/icons"

module Devmux
  # The plugins popover: a small modal TUI, launched in a centered tmux popup
  # (see UI's "p" key), listing every devmux plugin with an on/off checkbox.
  # j/k or the arrows move the selection, Enter toggles the highlighted plugin
  # (persisted to disk immediately), and c/q/Esc close the popup.
  #
  # It's its own process (the popup runs `devmux plugins-menu`), so it just reads
  # and writes the shared Plugins store; the manager UI re-renders when it regains
  # control after the popup closes.
  class PluginsMenu
    def initialize
      @sel = 0
    end

    def run
      IO.console.raw do
        render
        loop do
          case next_key
          when "j", :down then move(1)
          when "k", :up   then move(-1)
          when "\r", "\n" then toggle
          when "c", "q", "\e", "" then break
          end
          render
        end
      end
    rescue StandardError
      nil
    end

    private

    def plugins
      Plugins.all
    end

    def move(delta)
      return if plugins.empty?
      @sel = (@sel + delta).clamp(0, plugins.size - 1)
    end

    def toggle
      plugin = plugins[@sel]
      Plugins.toggle(plugin.id) if plugin
    end

    def render
      lines = ["devmux plugins", ""]
      plugins.each_with_index do |plugin, i|
        lines << row(plugin, i == @sel)
      end
      lines << ""
      lines << "[j/k] move   [↵] toggle   [c] close"
      draw(lines)
    end

    # One plugin row: selection cursor, an on/off checkbox (same glyphs as the
    # sidebar), the plugin's logo (Nerd Font only), and the name. A disabled
    # plugin is dimmed so the on/off state reads at a glance.
    def row(plugin, selected)
      cursor = selected ? "#{Icons.selector} " : "  "
      on = Plugins.enabled?(plugin.id)
      box = on ? Icons::CHECK_ON : Icons::CHECK_OFF
      logo = plugin.logo && Icons.nerd? ? "#{plugin.logo} " : ""
      text = "#{cursor}#{box} #{logo}#{plugin.name}"
      on ? text : dim(text)
    end

    def dim(str)
      "\e[2m#{str}\e[0m"
    end

    # Clear and paint the block centered in the popup (both axes) so it looks
    # like a titled card regardless of the popup's exact size.
    def draw(lines)
      rows, cols = size
      top = [(rows - lines.size) / 2, 0].max
      $stdout.write("\e[H\e[2J")
      top.times { $stdout.write("\r\n") }
      lines.each { |line| $stdout.write(center(line, cols) + "\r\n") }
      $stdout.flush
    end

    # Center a line, ignoring ANSI escapes when measuring its visible width.
    def center(str, cols)
      visible = str.gsub(/\e\[[0-9;]*m/, "").length
      pad = [(cols - visible) / 2, 0].max
      (" " * pad) + str
    end

    def size
      IO.console.winsize
    rescue StandardError
      [12, 46]
    end

    def next_key
      IO.select([$stdin])
      read_key
    rescue StandardError
      ""
    end

    # Read one keypress (raw mode), decoding the up/down arrows.
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
      else "\e"
      end
    rescue IO::WaitReadable, EOFError, StandardError
      ""
    end
  end
end
