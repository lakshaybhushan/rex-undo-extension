# Terminal output for install.sh and uninstall.sh, after https://vercel.com/design/cli.
# Everything goes to stderr. Rich output (a terminal whose TERM isn't dumb) uses the
# ✓ ! ✗ gutter; plain output uses words instead. Color only reinforces the words.

if [ -t 2 ] && [ "${TERM:-}" != dumb ]; then ui_rich=1; else ui_rich=; fi
# Precedence: NO_COLOR, then FORCE_COLOR (0 means off), then detection.
if [ -n "${NO_COLOR:-}" ]; then ui_color=
elif [ -n "${FORCE_COLOR+set}" ]; then if [ "$FORCE_COLOR" = 0 ]; then ui_color=; else ui_color=1; fi
else ui_color=$ui_rich; fi

ui_bold= ui_green= ui_yellow= ui_red= ui_cyan= ui_off=
if [ -n "$ui_color" ]; then
  e=$(printf '\033')
  ui_bold="$e[1m" ui_green="$e[32m" ui_yellow="$e[33m" ui_red="$e[31m" ui_cyan="$e[36m" ui_off="$e[0m"
fi

# A path for display, with $HOME as ~.
ui_path() { case $1 in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
# A path for a command people copy, quoted only when it needs it.
ui_arg() { case $1 in *[!A-Za-z0-9_./~-]*) printf '"%s"' "$1" ;; *) printf '%s' "$1" ;; esac; }

# Label/value row: the label in a 16-character column, the value at column 18.
ui_row() {
  if [ -n "$ui_rich" ]; then printf '  %-16s%s\n' "$1" "$2" >&2; else printf '%-16s%s\n' "$1" "$2" >&2; fi
}

# A line of text in the content column.
ui_line() {
  if [ -n "$ui_rich" ]; then printf '  %s\n' "$1" >&2; else printf '%s\n' "$1" >&2; fi
}

# The one primary result: ✓ Verb  target
ui_ok() {
  if [ -n "$ui_rich" ]; then printf '%s✓%s %s%-16s%s%s\n' "$ui_green" "$ui_off" "$ui_bold" "$1" "$ui_off" "$2" >&2
  else printf '%s %s\n' "$1" "$2" >&2; fi
}

ui_warn() {
  if [ -n "$ui_rich" ]; then printf '%s!%s %s\n' "$ui_yellow" "$ui_off" "$1" >&2
  else printf '%sWarning:%s %s\n' "$ui_yellow" "$ui_off" "$1" >&2; fi
}

ui_err() {
  if [ -n "$ui_rich" ]; then printf '%s✗%s %s\n' "$ui_red" "$ui_off" "$1" >&2
  else printf '%sError:%s %s\n' "$ui_red" "$ui_off" "$1" >&2; fi
}

# A next step or recovery: what it does, then the exact command on its own line.
ui_next() {
  if [ -n "$ui_rich" ]; then printf '\n  %s:\n    %s%s%s\n' "$1" "$ui_cyan" "$2" "$ui_off" >&2
  else printf '\n  %s:\n    %s\n' "$1" "$2" >&2; fi
}
# Recovery that isn't a command.
ui_hint() { printf '\n  %s\n' "$1" >&2; }
