#!/bin/sh
# install.sh and uninstall.sh against a scratch home, with a fake rex whose
# config reload starts the real supervisor while init.lua has the block.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  for p in $(pgrep -f "$tmp/"); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/home/dotfiles" "$tmp/home/.config/rex" "$tmp/home/.claude"
cat >"$tmp/bin/rex" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "config reload") grep -q -- '-- rex-undo begin' "\$XDG_CONFIG_HOME/rex/init.lua" &&
    REX_UNDO_REX="\$0" REX_UNDO_DIR="$root/rex-undo" nohup sh "$root/bin/rex-undo-watch" >/dev/null 2>&1 & ;;
  "--autostart=false do") exec sleep 30 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/rex"
# init.lua and settings.json live in a dotfiles folder, linked into place.
echo '-- my config' >"$tmp/home/dotfiles/init.lua"
echo '{}' >"$tmp/home/dotfiles/settings.json"
ln -s "$tmp/home/dotfiles/init.lua" "$tmp/home/.config/rex/init.lua"
ln -s "$tmp/home/dotfiles/settings.json" "$tmp/home/.claude/settings.json"

export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_STATE_HOME="$tmp/home/state" PATH="$tmp/bin:$PATH"
state=$XDG_STATE_HOME/rex-undo
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }

sh "$root/install.sh" 2>/dev/null
first=$(cat "$state/watcher.pid" 2>/dev/null)
check "install starts the watcher" '[ -n "$first" ]'
sh "$root/install.sh" 2>/dev/null
check "reinstall restarts the watcher on the new code" '[ -n "$(cat "$state/watcher.pid" 2>/dev/null)" ] && [ "$(cat "$state/watcher.pid")" != "$first" ] && ! kill -0 "$first" 2>/dev/null'
check "reinstall keeps one block" '[ "$(grep -c -- "-- rex-undo begin" "$tmp/home/dotfiles/init.lua")" = 1 ]'
check "symlinked init.lua and settings.json stay links" '[ -L "$XDG_CONFIG_HOME/rex/init.lua" ] && [ -L "$HOME/.claude/settings.json" ] && grep -q claude-session-start "$tmp/home/dotfiles/settings.json"'
sh "$root/uninstall.sh" 2>/dev/null
check "uninstall removes the block through the link" '[ -L "$XDG_CONFIG_HOME/rex/init.lua" ] && ! grep -q rex-undo "$tmp/home/dotfiles/init.lua" && grep -q "my config" "$tmp/home/dotfiles/init.lua"'
check "uninstall removes the hook" '! grep -q claude-session-start "$tmp/home/dotfiles/settings.json"'
check "uninstall stops the watcher and deletes the history" '[ ! -d "$state" ] && [ -z "$(pgrep -f "$tmp/")" ]'
exit $failed
