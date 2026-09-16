require "json"
require "open3"
require "devmux/plugin_store"

module Devmux
  module Plugins
    # The GitHub plugin. Beyond registering the `github:` identifier scheme and
    # seeding `tickets`/`prs` examples, it demonstrates the two richer plugin
    # capabilities:
    #
    #   - resource_details(id): report live state for a github resource (a PR's
    #     open/merged/closed status) and the color its sidebar icon should take.
    #   - poll(host): refresh the state of PRs already attached to a session, so
    #     their icon color/CI/merge-queue ETA stays current. (It does NOT discover
    #     or create sessions — the poll only touches PRs you've attached yourself.)
    #
    # It's a plain object implementing the devmux plugin interface (no base
    # class), and persists its state in a PluginStore it owns, so resource_details
    # (called from the UI) and poll (called from the poller thread) share it.
    class Github
      # Sidebar icon color per PR state (ANSI SGR params).
      STATE_COLORS = {
        "open"   => "38;5;40",  # green
        "draft"  => "38;5;245", # grey
        "queued" => "38;5;130", # brown (in the merge queue)
        "merged" => "38;5;141", # purple
        "closed" => "38;5;203", # red
      }.freeze

      # A PR in the merge queue swaps the PR glyph for a queue marker, in brown.
      QUEUED_ICON = { glyph: "\u{f4db}", color: "38;5;130" }.freeze

      # Extra decoration icon for a PR's CI rollup, shown beside the PR glyph.
      CI_ICONS = {
        "passing" => { glyph: "\u{f058}", color: "38;5;40" },  # check-circle, green
        "failing" => { glyph: "\u{f057}", color: "38;5;203" }, # x-circle, red
        "pending" => { glyph: "\u{f07c3}", color: "38;5;220" }, # in-progress, yellow
      }.freeze

      # The PR fields we pull, including the latest commit's aggregate check
      # rollup (SUCCESS/FAILURE/PENDING/…) for CI status.
      # Glyph + color for a PR with merge conflicts — replaces the normal PR glyph.
      CONFLICT_ICON = { glyph: "\u{ec6e}", color: "38;5;220" }.freeze # yellow

      PR_FIELDS =
        "title state isDraft mergeable url " \
        "mergeQueueEntry { estimatedTimeToMerge } " \
        "commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }"

      def initialize
        @store = PluginStore.new("github")
      end

      def id
        "github"
      end

      def name
        "GitHub"
      end

      def logo
        "\u{f09b}" # nf-fa-github
      end

      def provider
        {
          scheme: "github",
          body: %r{\A[\w.-]+/[\w.-]+/(?:issue|pull)/\d+\z},
          short: lambda do |body|
            _owner, repo, _type, number = body.split("/")
            "#{repo}##{number}"
          end,
        }
      end

      def examples_for(key)
        case key
        when "tickets" then ["github:owner/repo/issue/123"]
        when "prs"     then ["github:owner/repo/pull/1514"]
        else []
        end
      end

      # Browser URL for a github identifier (issue or PR), or nil if malformed.
      # github:owner/repo/issue/12 -> .../issues/12 ; .../pull/12 -> .../pull/12.
      def resource_url(identifier)
        _scheme, body = identifier.to_s.split(":", 2)
        owner, repo, type, number = body.to_s.split("/")
        return nil unless owner && repo && number && !number.empty?
        path = type == "pull" ? "pull" : "issues"
        "https://github.com/#{owner}/#{repo}/#{path}/#{number}"
      end

      # Details for a known github resource, or nil if we haven't seen it. May
      # carry `glyph:` (override the base PR glyph — used for a conflict), `color:`
      # (style the base glyph), and `icons:` (extra decoration icons — the CI
      # pass/fail glyph). A PR with merge conflicts swaps its glyph for a yellow
      # conflict marker; otherwise the glyph stays the generic PR icon in its
      # state color.
      def resource_details(identifier)
        rec = resources[identifier]
        return nil unless rec
        details =
          if rec["conflict"]
            { state: rec["state"], glyph: CONFLICT_ICON[:glyph], color: CONFLICT_ICON[:color] }
          elsif rec["state"] == "queued"
            d = { state: rec["state"], glyph: QUEUED_ICON[:glyph], color: QUEUED_ICON[:color] }
            eta = format_eta(rec["eta"])
            d[:annotation] = "(#{eta})" if eta
            d
          else
            { state: rec["state"], color: STATE_COLORS[rec["state"]] }
          end
        details[:title] = rec["title"] unless rec["title"].to_s.empty?
        ci = CI_ICONS[rec["ci"]]
        details[:icons] = [ci] if ci
        details
      end

      # One poll: refresh the cached state + CI of every PR already attached to a
      # session, so its sidebar/title icon color, CI glyph, and merge-queue ETA
      # stay current. Only touches PRs you've attached yourself — nothing is
      # discovered or created. A no-op (and no API call) when nothing is attached.
      def poll(host)
        attached_ids = host.sessions.flat_map { |s| s[:prs] }.select { |i| mine?(i) }.uniq
        return if attached_ids.empty?

        attached = fetch(host, attached_ids)
        return if attached.nil? # gh missing / not authenticated / offline — logged.

        host.log("github: refreshed #{attached.size}/#{attached_ids.size} attached PR(s) " \
                 "[#{state_summary(attached.values)}]")

        data = @store.read
        data["resources"] ||= {}
        attached.each { |id, pr| data["resources"][id] = store_rec(pr) }
        @store.write(data)
      end

      private

      def resources
        @store.read["resources"] || {}
      end

      def store_rec(pr)
        { "state" => pr[:state], "ci" => pr[:ci], "conflict" => pr[:conflict],
          "title" => pr[:title], "eta" => pr[:eta] }
      end

      # A compact per-state count for the log line, e.g. "open=1 merged=2".
      def state_summary(prs)
        STATE_COLORS.keys.map { |s| "#{s}=#{prs.count { |pr| pr[:state] == s }}" }
                    .reject { |pair| pair.end_with?("=0") }.join(" ")
      end

      # A compact estimated-time-to-merge from seconds: "<1m", "9m", "1h", "1h20m".
      def format_eta(seconds)
        return nil unless seconds
        minutes = (seconds.to_f / 60).round
        return "<1m" if minutes <= 0
        return "#{minutes}m" if minutes < 60
        hours, rem = minutes.divmod(60)
        rem.zero? ? "#{hours}h" : "#{hours}h#{rem}m"
      end

      # Fetch the current state of the attached PRs in one GraphQL request, and
      # return { id => pr }. Returns nil only on a hard failure (couldn't reach the
      # API / not authenticated); partial GraphQL errors (e.g. one inaccessible
      # attached PR) are logged but the rest of the data is still used.
      def fetch(host, attached_ids)
        host&.log("github:   $ gh api graphql — #{attached_ids.size} attached PR(s)")
        json = graphql(build_query(attached_ids), host)
        return nil unless json

        attached = {}
        attached_ids.each_with_index do |_id, i|
          pr = node_to_pr(json.dig("data", "a#{i}", "pullRequest"))
          attached[pr[:id]] = pr if pr
        end
        attached
      end

      # One aliased lookup per attached PR (by owner/repo/number), so we can
      # refresh each one's state regardless of age.
      def build_query(attached_ids)
        aliases = attached_ids.each_with_index.filter_map do |id, i|
          owner, repo, number = parse_id(id)
          next unless owner
          %(a#{i}: repository(owner: "#{owner}", name: "#{repo}") ) +
            %({ pullRequest(number: #{number}) { #{PR_FIELDS} } })
        end
        "query {\n  #{aliases.join("\n  ")}\n}"
      end

      # Return the parsed response hash when it carries a `data` payload (even if
      # it also has partial `errors`), else nil. A response with no `data` (an
      # auth error, an HTTP error body, unparseable output) is a hard failure.
      def graphql(query, host = nil)
        out, err, status = Open3.capture3("gh", "api", "graphql", "-f", "query=#{query}")
        json = (JSON.parse(out) rescue nil)
        if json.is_a?(Hash) && json["data"]
          if json["errors"]
            messages = Array(json["errors"]).filter_map { |e| e["message"] }.first(2).join("; ")
            host&.log("github:   ! graphql partial errors: #{messages}")
          end
          return json
        end
        detail = err.strip
        detail = out.strip if detail.empty?
        host&.log("github:   ! gh failed#{status.success? ? '' : " (exit #{status.exitstatus})"}: #{detail}")
        nil
      rescue StandardError => e
        host&.log("github:   ! could not run gh: #{e.class}: #{e.message}")
        nil
      end

      def node_to_pr(node)
        return nil unless node.is_a?(Hash)
        id = pr_identifier(node["url"])
        return nil unless id
        state = node["state"].to_s.downcase
        state = "open" unless STATE_COLORS.key?(state)
        state = "draft" if state == "open" && node["isDraft"]
        queue = node["mergeQueueEntry"]
        state = "queued" if state == "open" && queue
        # `mergeable` is only meaningful while the PR can still be merged; GitHub
        # leaves it as CONFLICTING on merged/closed PRs (notably after a stacked
        # merge), so only treat it as a conflict for an open-ish PR — otherwise a
        # merged PR would render with the yellow conflict icon instead of merged.
        conflict = %w[open draft queued].include?(state) && node["mergeable"] == "CONFLICTING"
        { id: id, title: node["title"].to_s, state: state, ci: ci_state(node),
          conflict: conflict,
          eta: queue && queue["estimatedTimeToMerge"] }
      end

      # "passing"/"failing"/"pending" from the latest commit's check rollup, or
      # nil when there are no checks at all.
      def ci_state(node)
        rollup = node.dig("commits", "nodes", 0, "commit", "statusCheckRollup", "state")
        case rollup
        when "SUCCESS" then "passing"
        when "FAILURE", "ERROR" then "failing"
        when "PENDING", "EXPECTED" then "pending"
        end
      end

      def pr_identifier(url)
        m = url.to_s.match(%r{github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)})
        m && "github:#{m[1]}/#{m[2]}/pull/#{m[3]}"
      end

      def mine?(identifier)
        identifier.to_s.match?(%r{\Agithub:[\w.-]+/[\w.-]+/pull/\d+\z})
      end

      def parse_id(identifier)
        _scheme, body = identifier.to_s.split(":", 2)
        owner, repo, type, number = body.to_s.split("/")
        return nil unless type == "pull" && number
        [owner, repo, number]
      end
    end
  end
end
