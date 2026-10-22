require "json"
require "fileutils"
require "devmux/context"

module Devmux
  module SidebarResources
    module_function

    FIXED = %w[branch tickets prs].freeze
    LABELS = { "branch" => "Branches", "tickets" => "Tickets", "prs" => "Pull requests" }.freeze

    def state_dir
      base = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
      File.join(base, "devmux", "tmux")
    end

    def store_path
      File.join(state_dir, "sidebar.json")
    end

    def kinds
      FIXED + (Context.identifier_keys - FIXED)
    end

    def label(kind)
      LABELS[kind] || kind.tr("_", " ").capitalize
    end

    def hidden
      return [] unless File.exist?(store_path)
      data = JSON.parse(File.read(store_path))
      data.is_a?(Hash) ? Array(data["hidden_resources"]).map(&:to_s) : []
    rescue StandardError
      []
    end

    def shown?(kind)
      !hidden.include?(kind)
    end

    def toggle(kind)
      list = hidden
      list = list.include?(kind) ? list - [kind] : list + [kind]
      FileUtils.mkdir_p(File.dirname(store_path))
      File.write(store_path, JSON.pretty_generate("hidden_resources" => list))
    end
  end
end
