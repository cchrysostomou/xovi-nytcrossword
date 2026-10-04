#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

export NYTCROSSWORD_CONFIG="${NYTCROSSWORD_CONFIG:-$ROOT_DIR/config.env}"
export NYTCROSSWORD_STATE_DIR="${NYTCROSSWORD_STATE_DIR:-$ROOT_DIR/state}"
export NYTCROSSWORD_QPDF="${NYTCROSSWORD_QPDF:-$ROOT_DIR/tools/bin/qpdf}"

if command -v bash >/dev/null 2>&1; then
  exec bash "$ROOT_DIR/scripts/nytcrossword-shell.sh" "$@"
fi
printf '%s\n' '{"ok":false,"error":"missing_dependency","message":"Bash is required for bounded XOVI broker access."}'
exit 1
