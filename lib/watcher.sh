# Stopping and checking the watcher supervisor (bin/rex-undo-watch), for
# install.sh and uninstall.sh. Each takes the state folder.

# True if no process holds the lock file $1. macOS has lockf, Linux has flock.
watcher_lock_free() {
  if command -v lockf >/dev/null 2>&1; then
    lockf -s -t 0 "$1" true 2>/dev/null
  else
    flock -n "$1" true 2>/dev/null
  fi
}

# Stops the running supervisor and the `rex do` it runs, and waits until its
# lock is free so the next copy can start. Returns 1 if none was running.
watcher_stop() {
  ws_pid=$(cat "$1/watcher.pid" 2>/dev/null) || return 1
  rm -f "$1/watcher.pid"
  ps -o command= -p "$ws_pid" 2>/dev/null | grep -q rex-undo-watch || return 1
  # TERM first: sh runs the trap only once its current command ends, so ending
  # the child first could let it start another before the TERM arrives.
  kill "$ws_pid" 2>/dev/null || true
  pkill -P "$ws_pid" 2>/dev/null || true
  ws_i=0
  until watcher_lock_free "$1/watcher.lock" || [ "$ws_i" -ge 30 ]; do
    sleep 0.1
    ws_i=$((ws_i + 1))
  done
  return 0
}

# Waits up to 3s for a supervisor to start. Returns 1 if none did.
watcher_wait() {
  ws_i=0
  until [ -s "$1/watcher.pid" ]; do
    [ "$ws_i" -ge 30 ] && return 1
    sleep 0.1
    ws_i=$((ws_i + 1))
  done
}
