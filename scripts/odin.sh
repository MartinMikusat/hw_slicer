#!/bin/sh
set -eu

if [ "${1:-}" = "--print-path" ]; then
  exec hw-odin toolchain path
fi

case "${1:-}" in
  build|bundle|check|run|test)
    COMMAND=$1
    shift
    TARGET=${1:-}
    if [ -z "$TARGET" ]; then
      exec hw-odin "$COMMAND"
    fi
    shift
    exec hw-odin "$COMMAND" "$TARGET" -no-threaded-checker "$@"
    ;;
esac

exec hw-odin "$@"
