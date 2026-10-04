#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

export NYTCROSSWORD_CONFIG="${NYTCROSSWORD_CONFIG:-$ROOT_DIR/config.env}"
export NYTCROSSWORD_STATE_DIR="${NYTCROSSWORD_STATE_DIR:-$ROOT_DIR/state}"

exec sh "$ROOT_DIR/scripts/nytcrossword-shell.sh" "$@"
