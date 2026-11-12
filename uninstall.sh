#!/bin/sh
# Removes what install.sh added, and the undo history: it holds command lines
# as they were typed, which can include secrets. To update, run install.sh
# again instead; it keeps the history.
set -eu

root=$(cd "$(dirname "$0")" && pwd)
. "$root/lib/ui.sh"
. "$root/lib/watcher.sh"
config=${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua
settings=$HOME/.claude/settings.json
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex-undo
stopped= unconfigured= unhooked= deleted= config_warning= hook_warning=

# Stop the watcher first, so a later failure can't leave it running.
if watcher_stop "$state"; then stopped=1; fi

# Both markers must be there, or sed would delete to the end of the file.
if [ -f "$config" ] && grep -qx -- '-- rex-undo begin' "$config" && grep -qx -- '-- rex-undo end' "$config"; then
  sed -i '' '/^-- rex-undo begin$/,/^-- rex-undo end$/d' "$config"
  unconfigured=1
elif [ -f "$config" ] && grep -q -- '-- rex-undo' "$config"; then
  config_warning="Left $(ui_path "$config") alone: it has a partial rex-undo block. Delete it by hand."
fi

if [ -f "$settings" ] && grep -q 'claude-session-start.sh' "$settings"; then
  if command -v jq >/dev/null 2>&1 && jq '.hooks.SessionStart |= map(select((.hooks // []) | all((.command // "") | test("claude-session-start\\.sh") | not)))' \
    "$settings" >"$settings.tmp" 2>/dev/null; then
    mv "$settings.tmp" "$settings"
    unhooked=1
  else
    rm -f "$settings.tmp"
    hook_warning="Couldn't edit $(ui_path "$settings"). Delete the claude-session-start.sh hook by hand."
  fi
fi

command -v rex >/dev/null 2>&1 && rex config reload >/dev/null 2>&1 || true

if [ -d "$state" ]; then
  rm -rf "$state"
  deleted=1
fi

if [ -n "$stopped$unconfigured$unhooked$deleted" ]; then
  ui_ok Uninstalled rex-undo
  if [ -n "$stopped" ]; then ui_row "Watcher" "stopped"; fi
  if [ -n "$unconfigured" ]; then ui_row "Rex config" "$(ui_path "$config")"; fi
  if [ -n "$unhooked" ]; then ui_row "Claude hook" "$(ui_path "$settings")"; fi
  if [ -n "$deleted" ]; then ui_row "History" "deleted"; fi
else
  ui_line "rex-undo isn't installed. Nothing to remove."
fi
if [ -n "$config_warning" ]; then ui_warn "$config_warning"; fi
if [ -n "$hook_warning" ]; then ui_warn "$hook_warning"; fi
