#!/bin/sh
# Claude Code SessionStart hook for rex-undo. Records which conversation runs
# in this Rex pane, so reopening the pane can run `claude --resume ID`.
# It prints nothing, because Claude adds a hook's output to the conversation.

[ -n "${REX_BLOCK:-}" ] || exit 0
# herdr passes the Rex pane ID on to its own panes and resumes those itself.
[ "${HERDR_ENV:-}" = 1 ] && exit 0
# The ID becomes a file name, so allow only what Rex block IDs contain.
case ${REX_BLOCK#block:} in '' | *[!0-9a-fA-F-]*) exit 0 ;; esac
# A Claude started by a tool, such as `claude -p`, has no terminal and isn't
# the conversation in this pane.
pid=${CLAUDE_PID:-$PPID}
case $pid in '' | *[!0-9]*) exit 0 ;; esac
case $(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ') in '' | '?' | '??') exit 0 ;; esac
input=$(cat)
# Subagents belong to the conversation that started them.
case $input in *'"agent_id"'*) exit 0 ;; esac
case $input in *'"session_id"'*) ;; *) exit 0 ;; esac
# The watcher trusts the record only while this Claude is the one in the pane.
case $input in *'{'*) input="{\"rex_pid\":$pid,${input#*\{}" ;; *) exit 0 ;; esac

dir=${XDG_STATE_HOME:-$HOME/.local/state}/rex-undo/claude
mkdir -p "$dir" || exit 0
file=$dir/${REX_BLOCK#block:}.json
printf '%s\n' "$input" >"$file.$$" && mv "$file.$$" "$file"
rm -f "$file.$$"
exit 0
