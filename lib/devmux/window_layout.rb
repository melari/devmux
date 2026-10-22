require "json"
require "open3"
require "fileutils"

module Devmux
  module WindowLayout
    module_function

    TERMINAL_RATIO = 1.0 / 3

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def store_path
      File.join(state_dir, "window-layout.json")
    end

    def saved?
      File.exist?(store_path)
    end

    def split(terminal_client_pids, browser_pid)
      return false unless browser_pid
      candidates = terminal_client_pids.flat_map { |pid| ancestors(pid) }.uniq
      return false if candidates.empty?
      out = jxa("split", { terminalPids: candidates, browserPid: browser_pid, terminalRatio: TERMINAL_RATIO })
      return false unless out
      unless saved?
        FileUtils.mkdir_p(state_dir)
        File.write(store_path, out)
      end
      true
    end

    def restore
      return false unless saved?
      saved = File.read(store_path)
      ok = !jxa("restore", JSON.parse(saved)).nil?
      File.delete(store_path) if ok
      ok
    rescue StandardError
      false
    end

    def ancestors(pid)
      chain = []
      while pid && pid > 1 && chain.size < 20
        chain << pid
        out, status = Open3.capture2("ps", "-o", "ppid=", "-p", pid.to_s)
        break unless status.success?
        pid = out.strip.to_i
      end
      chain
    end

    def jxa(mode, args)
      out, _err, status = Open3.capture3("osascript", "-l", "JavaScript", "-e", SCRIPT,
                                         mode, JSON.generate(args))
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    SCRIPT = <<~'JXA'.freeze
      ObjC.import("AppKit")

      function run(argv) {
        const mode = argv[0]
        const args = JSON.parse(argv[1])
        const se = Application("System Events")
        const proc = pid => {
          const found = se.processes.whose({ unixId: pid })
          return found.length ? found[0] : null
        }
        const frame = (pid, win) => ({ pid: pid, position: win.position(), size: win.size() })
        const place = (win, x, y, width, height) => {
          win.size = [width, height]
          win.position = [x, y]
          win.size = [width, height]
          win.position = [x, y]
          return { position: win.position(), size: win.size() }
        }
        const same = (a, b) => a[0] === b[0] && a[1] === b[1]
        const at = (win, placed) => {
          try {
            return same(win.position(), placed.position) && same(win.size(), placed.size)
          } catch (e) {
            return false
          }
        }

        if (mode === "split") {
          const term = args.terminalPids.map(proc).find(p => p && p.windows.length > 0)
          const browser = waitForWindow(proc, args.browserPid)
          if (!term || !browser) throw new Error("windows not found")
          const termWin = term.windows[0]
          const browserWin = browser.windows[0]
          const saved = { terminal: frame(term.unixId(), termWin), browser: frame(args.browserPid, browserWin) }
          const area = screenFor(termWin.position(), termWin.size())
          const termWidth = Math.floor(area.width * args.terminalRatio)
          saved.terminal.placed = place(termWin, area.x, area.y, termWidth, area.height)
          saved.browser.placed = place(browserWin, area.x + termWidth, area.y, area.width - termWidth, area.height)
          return JSON.stringify(saved)
        }

        if (mode === "restore") {
          for (const key of Object.keys(args)) {
            const entry = args[key]
            const p = proc(entry.pid)
            if (!p || p.windows.length === 0) continue
            const wins = p.windows()
            const placed = entry.placed
            const win = (placed && wins.find(w => at(w, placed))) || wins[0]
            try {
              place(win, entry.position[0], entry.position[1], entry.size[0], entry.size[1])
            } catch (e) {}
          }
          return "ok"
        }

        throw new Error("unknown mode " + mode)
      }

      function waitForWindow(proc, pid) {
        for (let i = 0; i < 20; i++) {
          const p = proc(pid)
          if (p && p.windows.length > 0) return p
          delay(0.1)
        }
        return null
      }

      function screenFor(pos, size) {
        const screens = $.NSScreen.screens
        const primaryHeight = screens.objectAtIndex(0).frame.size.height
        const cx = pos[0] + size[0] / 2
        const cy = pos[1] + size[1] / 2
        let visible = screens.objectAtIndex(0).visibleFrame
        for (let i = 0; i < screens.count; i++) {
          const screen = screens.objectAtIndex(i)
          const f = screen.frame
          const top = primaryHeight - (f.origin.y + f.size.height)
          if (cx >= f.origin.x && cx < f.origin.x + f.size.width && cy >= top && cy < top + f.size.height) {
            visible = screen.visibleFrame
            break
          }
        }
        return {
          x: visible.origin.x,
          y: primaryHeight - (visible.origin.y + visible.size.height),
          width: visible.size.width,
          height: visible.size.height,
        }
      }
    JXA
  end
end
