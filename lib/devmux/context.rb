require "devmux/providers"
require "devmux/plugins"

module Devmux
  # A session's context: generic key/value pairs an agent (or, later, a devmux
  # plugin) can read and write via `devmux context read|write`. Values may be
  # scalars or arrays.
  #
  # The schema below is the set of keys allowed for now; it's deliberately a
  # plain table so plugins can extend it later. Each entry gives a default and
  # whether the value is an array. `name` defaults to the agent's own slug (so a
  # session always reports a usable name); everything else uses its listed
  # default.
  module Context
    KEYS = {
      "name" => {
        default: nil, array: false,
        description: "A short title to remind the user what this session is. 25 chars max.",
      },
      "worktree" => {
        default: nil, array: false,
        description: "Absolute path to the git worktree this session works in, or null if none.",
      },
      "prs" => {
        default: [], array: true, identifier: true,
        description: "Pull requests as scheme-prefixed ids (include the repo). Multiple allowed. See examples.",
      },
      "tickets" => {
        default: [], array: true, identifier: true,
        description: "Tickets as scheme-prefixed ids. Multiple allowed. See examples.",
      },
      "agent_state" => {
        default: "needs_input", array: false,
        description: "Set automatically by devmux hooks: 'busy' while working, 'needs_input' when waiting for you. You don't set this yourself.",
      },
    }.freeze

    module_function

    # The full schema: the built-in keys plus any contributed by enabled plugins
    # (e.g. slack's `slack_threads`). Computed fresh so enabling/disabling a
    # plugin adds/removes its keys.
    def keys
      KEYS.merge(Plugins.context_keys)
    end

    # Identifier keys (tickets, prs, and any plugin ones like slack_threads) — the
    # ones holding scheme-prefixed ids that render as resource icons.
    def identifier_keys
      keys.select { |_key, spec| spec[:identifier] }.keys
    end

    def key?(key)
      keys.key?(key)
    end

    def array?(key)
      spec = keys[key]
      !!(spec && spec[:array])
    end

    # Stored context merged over the schema defaults, so every allowed key is
    # present. `record` is the registry record, used for the `name` fallback.
    # Extra (e.g. disabled-plugin) keys already stored are preserved.
    def with_defaults(stored, record)
      stored ||= {}
      merged = {}
      keys.each do |key, spec|
        merged[key] =
          if stored.key?(key)
            stored[key]
          elsif key == "name"
            record["name"]
          else
            dup(spec[:default])
          end
      end
      stored.each { |k, v| merged[k] = v unless merged.key?(k) }
      merged
    end

    # Annotate a value map with each key's description (and any example values
    # contributed by enabled plugins), so `context read` teaches an agent what to
    # put where: { key => { "value" =>, "description" =>, "examples" => [...] } }.
    # `examples` is omitted for keys no plugin supplies (name, worktree, ...).
    def annotate(values)
      values.each_with_object({}) do |(key, value), out|
        entry = { "value" => value, "description" => description(key) }
        examples = Plugins.examples_for(key)
        entry["examples"] = examples unless examples.empty?
        out[key] = entry
      end
    end

    def description(key)
      spec = keys[key]
      spec && spec[:description]
    end

    # Turn a CLI value list into a stored value per the key's arity: arrays keep
    # the list, scalars join into one string.
    def coerce(key, values)
      array?(key) ? values : values.join(" ")
    end

    # Validate a value for a key; returns an error string, or nil if OK.
    # Identifier keys (tickets, prs) require well-formed scheme-prefixed ids.
    def validate(key, value)
      spec = keys[key]
      return nil unless spec && spec[:identifier]
      bad = Array(value).reject { |v| Providers.valid?(v) }
      return nil if bad.empty?
      examples = Plugins.examples_for(key)
      hint = examples.empty? ? "scheme-prefixed identifiers" : "scheme-prefixed identifiers like #{examples.join(', ')}"
      "#{key} must be #{hint} (got: #{bad.join(', ')})"
    end

    def dup(value)
      value.is_a?(Array) ? value.dup : value
    end
  end
end
