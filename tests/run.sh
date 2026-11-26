#!/bin/sh
# Runs the regression tests against a temporary state directory.
root=$(cd "$(dirname "$0")/.." && pwd)
export XDG_STATE_HOME=$(mktemp -d)
trap 'rm -rf "$XDG_STATE_HOME"' EXIT
luajit "$root/tests/run.lua" "$root" &&
  sh "$root/tests/supervisor_test.sh" 2>/dev/null &&
  sh "$root/tests/install_test.sh" || exit 1
if command -v "${REX:-rex}" >/dev/null 2>&1; then
  sh "$root/tests/stack_lock_test.sh"
fi
