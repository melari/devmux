require "devmux/tmux"

module Devmux
  module Drawer
    MANAGER_TITLE = "devmux-manager".freeze
    # Session options coupling the sidebar selection and pane focus across the
    # Ctrl-Space toggle (which runs in a separate process from the UI):
    #   HOVER_OPTION  — the UI publishes the currently-selected agent's name here,
    #                   so collapsing focuses that agent's pane.
    #   SELECT_OPTION — on expand, toggle! records the agent that was focused here,
    #                   so the UI can move its selection to that entry.
    HOVER_OPTION = "@devmux_hover".freeze
    SELECT_OPTION = "@devmux_select".freeze
    WIDTH_OPTION = "@devmux_width".freeze

    # Drawer widths in columns. Collapsed sits below UI::COMPACT_MAX_COLS so the
    # sidebar renders its compact view; expanded sits above it, sized to the UI's
    # published content width (WIDTH_OPTION) within MIN_EXPANDED_WIDTH and half
    # the window, falling back to EXPANDED_WIDTH when none is published.
    COLLAPSED_WIDTH = 16
    MIN_EXPANDED_WIDTH = 24
    EXPANDED_WIDTH = 44

    module_function

    # Global Ctrl-Space handler, invoked as a standalone process by the keybind.
    # It reads the manager's current width to decide direction. The sidebar
    # selection and pane focus stay coupled via two session options (see
    # HOVER_OPTION / SELECT_OPTION):
    #   - Expanding records the agent that was focused (SELECT_OPTION) so the UI
    #     hovers its entry, then focuses the manager.
    #   - Collapsing focuses the pane of the currently-hovered entry (HOVER_OPTION),
    #     falling back to the last-active pane when it has none.
    def toggle!(tmux = Tmux.new)
      panes = tmux.panes
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return unless manager

      if manager[:width] <= (COLLAPSED_WIDTH + MIN_EXPANDED_WIDTH) / 2
        active = panes.find { |p| p[:active] }
        select = ["set-option", "-t", Tmux::SESSION, SELECT_OPTION, (active && active[:agent]) || ""]
        width = expanded_width(panes, tmux.get_option(WIDTH_OPTION).to_i)
        tmux.batch([select] + layout_commands(panes, width) + [["select-pane", "-t", manager[:id]]])
      else
        hovered = tmux.get_option(HOVER_OPTION)
        pane = hovered.to_s.empty? ? nil : panes.find { |p| p[:agent] == hovered }
        focus = pane ? ["select-pane", "-t", pane[:id]] : ["select-pane", "-t", Tmux::SESSION, "-l"]
        tmux.batch(layout_commands(panes, COLLAPSED_WIDTH) + [focus])
      end
    end

    # Give every agent pane an equal share of the width left over after the
    # manager: set each agent (bar the last, which absorbs the rounding
    # remainder) to `each` columns, left to right.
    def rebalance_agents(tmux)
      panes = tmux.panes
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return unless manager
      tmux.batch(agent_resize_commands(panes, manager[:width]))
    end

    # Resize the manager drawer to `manager_width` AND re-even the agents to the
    # width left over — all in ONE tmux invocation, so tmux reflows and redraws
    # once instead of flickering the agent panes through intermediate widths on
    # every expand/collapse.
    def set_layout(tmux, manager_width)
      tmux.batch(layout_commands(tmux.panes, manager_width))
    end

    def expand(tmux, content_width)
      panes = tmux.panes
      tmux.batch(layout_commands(panes, expanded_width(panes, content_width)))
    end

    def expanded_width(panes, content_width)
      return EXPANDED_WIDTH unless content_width.positive?
      max = panes.first ? panes.first[:window_width] / 2 : content_width
      content_width.clamp(MIN_EXPANDED_WIDTH, [max, MIN_EXPANDED_WIDTH].max)
    end

    def layout_commands(panes, manager_width)
      manager = panes.find { |p| p[:title] == MANAGER_TITLE }
      return [] unless manager
      agents = agent_resize_commands(panes, manager_width)
      settled = manager[:width] == manager_width &&
                agents.all? { |cmd| panes.find { |p| p[:id] == cmd[2] }&.dig(:width) == cmd[4].to_i }
      return [] if settled
      [["resize-pane", "-t", manager[:id], "-x", manager_width.to_s]] + agents
    end

    # The resize commands (arg arrays) that even out the agent columns for a given
    # manager width. Only real agent panes (@devmux_agent) count — a vim "show"
    # pane shares its agent's column, so resizing the agent resizes it too.
    def agent_resize_commands(panes, manager_width)
      agents = panes.select { |p| p[:agent] }
      return [] if agents.empty?
      count = agents.size
      avail = panes.first[:window_width] - manager_width - count
      each = avail / count
      return [] if each < 1
      agents[0...-1].map { |a| ["resize-pane", "-t", a[:id], "-x", each.to_s] }
    end
  end
end
