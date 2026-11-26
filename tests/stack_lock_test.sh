#!/bin/sh
# Exercise the actual Rex subprocess handle and macOS kernel lock.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
rex=${REX:-rex}
tmp=$(mktemp -d)
holder= contender= server=
cleanup() {
  for pid in $holder $contender; do kill -KILL "$pid" 2>/dev/null || true; done
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export XDG_STATE_HOME="$tmp"
export REX_UNDO_TEST_ROOT="$root"
socket="unix://$tmp/rex.sock"
cat >"$tmp/init.lua" <<'LUA'
local lib = dofile(os.getenv("REX_UNDO_TEST_ROOT") .. "/rex-undo/lib.lua")
rex.action{ name = "stack_lock_test", title = "Test stack lock", run = function()
  assert(lib.locked(function() return "ok" end) == "ok")
end }
LUA
"$rex" server run --listen "$socket" --state-dir "$tmp/server" --config "$tmp/init.lua" --restore=false >"$tmp/server.log" 2>&1 &
server=$!
attempts=0
until "$rex" --autostart=false -S "$socket" --timeout 1s api call server.status >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 100 ] || ! kill -0 "$server" 2>/dev/null; then
    cat "$tmp/server.log" >&2
    exit 1
  fi
  sleep 0.05
done

run_script() {
  "$rex" --autostart=false -S "$socket" do -e "$1"
}

# A leftover directory from the previous implementation must not block the
# new lock, and an error in a critical section must still release it.
mkdir -p "$tmp/rex-undo/stack.lock"
if ! "$rex" --autostart=false -S "$socket" do stack_lock_test; then
  cat "$tmp/server.log" >&2
  exit 1
fi
run_script '
  local lib = dofile(os.getenv("REX_UNDO_TEST_ROOT") .. "/rex-undo/lib.lua")
  local ok, err = pcall(lib.locked, function() error("expected error") end)
  assert(not ok and tostring(err):find("expected error", 1, true))
  assert(lib.locked(function() return "released" end) == "released")
'

"$rex" --autostart=false -S "$socket" do -e '
  local lib = dofile(os.getenv("REX_UNDO_TEST_ROOT") .. "/rex-undo/lib.lua")
  lib.locked(function()
    local ready = assert(io.open(os.getenv("XDG_STATE_HOME") .. "/holder-ready", "w"))
    ready:close()
    rex.sleep(30)
  end)
' &
holder=$!
attempts=0
until [ -f "$tmp/holder-ready" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || exit 1
  sleep 0.05
done
kill -STOP "$holder"

"$rex" --autostart=false -S "$socket" do -e '
  local lib = dofile(os.getenv("REX_UNDO_TEST_ROOT") .. "/rex-undo/lib.lua")
  lib.locked(function()
    local entered = assert(io.open(os.getenv("XDG_STATE_HOME") .. "/contender-entered", "w"))
    entered:close()
  end)
' &
contender=$!
sleep 6
[ ! -e "$tmp/contender-entered" ]
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
holder=
wait "$contender"
contender=
[ -f "$tmp/contender-entered" ]
printf '%s\n' 'PASS: a paused holder keeps its lock, and a dead holder releases it'
