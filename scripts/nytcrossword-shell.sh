#!/bin/sh
# Shell backend for the NYT Crossword AppLoad app. Every command prints a single
# JSON object on stdout so the QML frontend can parse it directly.
set -eu

VERSION="0.1.0"
CONFIG="${NYTCROSSWORD_CONFIG:-}"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

fail() {
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(json_escape "$2")"
  exit "${3:-1}"
}

# Reads KEY from the KEY=value config file without sourcing it.
config_value() {
  [ -n "$CONFIG" ] && [ -f "$CONFIG" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" | tail -n 1 | tr -d '\r'
}

cmd_version() {
  printf '{"ok":true,"version":"%s"}\n' "$VERSION"
}

cmd_status() {
  configured=false
  [ -n "$(config_value NYT_S_COOKIE)" ] && configured=true
  printf '{"ok":true,"version":"%s","configured":%s}\n' "$VERSION" "$configured"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  version) cmd_version ;;
  status) cmd_status ;;
  "") fail usage_error "Usage: nytcrossword-run.sh <version|status>" 2 ;;
  *) fail unknown_command "Unknown command: $command" 2 ;;
esac
