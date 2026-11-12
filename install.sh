#!/bin/sh
# Installs rex-undo: a block in Rex's init.lua and a Claude Code SessionStart hook.
# Safe to run again; run it again after moving or updating this folder.
set -eu

root=$(cd "$(dirname "$0")" && pwd)
. "$root/lib/ui.sh"
. "$root/lib/watcher.sh"
config=${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua
settings=$HOME/.claude/settings.json
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex-undo
hook="sh \"$root/hooks/claude-session-start.sh\""
key=${REX_UNDO_KEY:-cmd+shift+t}
history=${REX_UNDO_HISTORY:-50}
again=$(ui_arg "$root/install.sh")

# Rex's installer doesn't always put rex on PATH, so fall back to where Rex keeps it.
rex=$(command -v rex 2>/dev/null) || rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [ ! -x "$rex" ]; then
  ui_err "Can't find rex."
  ui_hint "Open Rex once, or put rex on PATH, then run this again."
  exit 1
fi
case $root$rex$key in *'"'*|*'\'*)
  ui_err "Can't install from a path, or with a REX_UNDO_KEY, that contains quotes or backslashes."
  ui_hint "Move this folder to a path without them, then run install.sh from there."
  exit 1 ;;
esac

case $history in '' | *[!0-9]*) n=0 ;; *) n=$history ;; esac
if [ "$n" -lt 1 ]; then
  ui_err "REX_UNDO_HISTORY must be a whole number, 1 or more, not '$history'."
  ui_next "Install with a number of closes to keep" "REX_UNDO_HISTORY=100 $again"
  exit 1
fi

mkdir -p "$(dirname "$config")"
# Replace an earlier block, which may point at a folder from another install or Mac.
verb=Installed
if [ -f "$config" ] && grep -qx -- '-- rex-undo begin' "$config" && grep -qx -- '-- rex-undo end' "$config"; then
  sed -i '' '/^-- rex-undo begin$/,/^-- rex-undo end$/d' "$config"
  verb=Updated
elif [ -f "$config" ] && grep -q -- '-- rex-undo' "$config"; then
  ui_err "Can't update $(ui_path "$config"): it has a partial rex-undo block."
  ui_hint "Delete the lines from '-- rex-undo begin' to '-- rex-undo end', then run this again."
  exit 1
fi
# pcall: if this folder goes missing (moved, or init.lua synced to another Mac),
# Rex logs it and loads the rest of the config.
cat >>"$config" <<EOF
-- rex-undo begin
do
  local ok, err = pcall(function()
    dofile("$root/rex-undo/undo.lua").setup{
      dir = "$root/rex-undo",
      rex = "$rex",
      key = "$key",
      history = $history,
    }
  end)
  if not ok then rex.log("rex-undo: not loaded: " .. tostring(err)) end
end
-- rex-undo end
EOF

hook_ok= hook_warning=
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$(dirname "$settings")"
  [ -f "$settings" ] || echo '{}' >"$settings"
  cp "$settings" "$settings.rex-undo.bak"
  # Drop any earlier rex-undo hook, then add this folder's.
  if jq --arg cmd "$hook" '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks // []) | all((.command // "") | test("claude-session-start\\.sh") | not)))) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])' \
    "$settings.rex-undo.bak" >"$settings.tmp" 2>/dev/null; then
    mv "$settings.tmp" "$settings"
    hook_ok=1
  else
    rm -f "$settings.tmp"
    hook_warning="Skipped the Claude hook: $(ui_path "$settings") isn't valid JSON. Claude panes will reopen with --continue."
  fi
else
  hook_warning="Skipped the Claude hook: jq isn't installed. Claude panes will reopen with --continue."
fi
if ! out=$("$rex" config check 2>&1); then
  ui_err "Rex couldn't load $(ui_path "$config")."
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  ui_next "Fix the error, then load it again" "$again"
  exit 1
fi

# A running watcher keeps the code it started with, and a new copy exits
# while it holds the lock. Stop it so the reload starts this folder's.
watcher_stop "$state" || true
reloaded= watcher=
if "$rex" config reload >/dev/null 2>&1; then
  reloaded=1
  if watcher_wait "$state"; then watcher=1; fi
fi

ui_ok "$verb" rex-undo
ui_row "Key" "$key reopens the last close"
ui_row "History" "last $history closes"
if [ -n "$watcher" ]; then ui_row "Watcher" "running"; fi
ui_row "Rex config" "$(ui_path "$config")"
if [ -n "$hook_ok" ]; then
  ui_row "Claude hook" "$(ui_path "$settings")"
  ui_row "Backup" "$(ui_path "$settings.rex-undo.bak")"
fi
if [ -n "$hook_warning" ]; then ui_warn "$hook_warning"; fi
if [ -z "$reloaded" ]; then
  ui_warn "Couldn't reach Rex to reload its config. rex-undo starts the next time Rex does."
elif [ -z "$watcher" ]; then
  ui_warn "The watcher didn't start, so closes aren't recorded. Its log is $(ui_path "$state/watcher.log")."
fi
if command -v rex >/dev/null 2>&1; then ui_next "List what can come back" "rex do undo_history"; fi
