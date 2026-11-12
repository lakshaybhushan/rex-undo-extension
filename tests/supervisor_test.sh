#!/bin/sh
# Starts many copies of bin/rex-undo-watch at once over a stale pidfile; exactly one may run.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
# Stop the winning copy by its pidfile: its own command line doesn't name $tmp.
cleanup() {
  pid=$(cat "$tmp/state/rex-undo/watcher.pid" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  pkill -f "$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
printf '#!/bin/sh\nsleep 30\n' >"$tmp/rex"; chmod +x "$tmp/rex"
mkdir -p "$tmp/state/rex-undo"
echo 99999 >"$tmp/state/rex-undo/watcher.pid"  # stale: no such process
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  XDG_STATE_HOME=$tmp/state REX_UNDO_REX=$tmp/rex REX_UNDO_DIR=$tmp sh "$root/bin/rex-undo-watch" &
done
sleep 2
n=$(pgrep -f "$tmp/rex" | wc -l | tr -d ' ')
if [ "$n" = 1 ]; then echo "ok supervisor: one watcher"; else echo "FAIL supervisor: $n watchers"; exit 1; fi
