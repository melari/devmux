#!/usr/bin/env bash
set -euo pipefail

RUBY_VERSION="$(cat "$(dirname "$0")/../.ruby-version" | tr -d '[:space:]')"

log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }

ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    log "Homebrew is required but not installed. Install it from https://brew.sh and re-run."
    exit 1
  fi
}

ensure_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    log "tmux present: $(tmux -V)"
  else
    log "installing tmux via Homebrew"
    brew install tmux
  fi
}

ensure_diffnav() {
  if command -v diffnav >/dev/null 2>&1; then
    log "diffnav present"
  else
    log "installing diffnav via Homebrew (the diff viewer devmux's 'd' key uses)"
    brew install diffnav
  fi
}

ensure_rbenv() {
  if command -v rbenv >/dev/null 2>&1; then
    log "rbenv present"
  else
    log "installing rbenv via Homebrew"
    brew install rbenv
  fi
  eval "$(rbenv init - bash)"
}

ensure_ruby() {
  if rbenv versions --bare 2>/dev/null | grep -qx "$RUBY_VERSION"; then
    log "ruby $RUBY_VERSION present"
  else
    log "installing ruby $RUBY_VERSION (this may take a while)"
    rbenv install --skip-existing "$RUBY_VERSION"
  fi
  rbenv rehash
}

ensure_brew
ensure_tmux
ensure_diffnav
ensure_rbenv
ensure_ruby

log "done"
