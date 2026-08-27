require "devmux/plugins"

module Devmux
  # Identifier schemes for context values like tickets and PRs. Each value is a
  # "scheme:body" string — e.g. linear:MAT-123, github:owner/repo/issue/123,
  # github:owner/repo/pull/1514 — so we always know which system an id belongs to
  # (and, for GitHub, which repo).
  #
  # The schemes themselves live in plugins (see Devmux::Plugins): each enabled
  # plugin may register one provider def { scheme:, body:, short: }. This module
  # is just the lookup/validation layer over whatever plugins are switched on, so
  # disabling a plugin makes its scheme unknown here too.
  module Providers
    module_function

    # Provider defs from the currently-enabled plugins.
    def providers
      Plugins.providers
    end

    # Is `identifier` a well-formed "scheme:body" for an enabled scheme?
    def valid?(identifier)
      scheme, body = split(identifier)
      provider = for_scheme(scheme)
      !!(provider && body && body.match?(provider[:body]))
    end

    # A compact form for display, e.g. linear:MAT-123 -> MAT-123,
    # github:clio/themis/pull/1514 -> themis#1514. Unknown -> unchanged.
    def short(identifier)
      scheme, body = split(identifier)
      provider = for_scheme(scheme)
      provider && body ? provider[:short].call(body) : identifier.to_s
    end

    def for_scheme(scheme)
      providers.find { |p| p[:scheme] == scheme }
    end

    def split(identifier)
      identifier.to_s.split(":", 2)
    end
  end
end
