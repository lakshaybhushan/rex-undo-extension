# rex-undo

Reopen the pane, tab, or session you just closed in [Rex](https://www.superlogical.com/rex),
with whatever was running in it. Press `cmd+shift+t`.

- A shell comes back in the same folder.
- A command comes back running again, with the command line it was started with.
- An agent comes back in the same conversation: `claude --resume ID`, `codex resume ID`,
  `fx --resume-ID`, and so on. See [`rex-undo/agents.lua`](rex-undo/agents.lua).

Panes return to the same side of the same split, tabs to the same place in the tab bar,
and sessions with every tab.

## Install

Requires Rex and `jq`.

```sh
./install.sh
```

This adds a block to `~/.config/rex/init.lua`, adds a Claude Code `SessionStart` hook to
`~/.claude/settings.json` (after a backup), and reloads the Rex config. Set
`REX_UNDO_KEY` to use another key, and `REX_UNDO_HISTORY` to keep more or fewer than
50 closes:

```sh
REX_UNDO_HISTORY=200 ./install.sh
```

Both point at this folder, so keep it where it is. After moving or updating it, or on a
Mac whose `init.lua` came from another machine, run `./install.sh` again: it replaces the
old block and hook, restarts the watcher on the new code, and keeps the history. Until
you do, Rex logs `rex-undo: not loaded` and loads the rest of the config.
`jq` ships with macOS 15 and later; without it, Claude panes reopen with `--continue`.

## Use

| Command | Does |
| --- | --- |
| `cmd+shift+t` or Reopen Closed Pane in the palette | Reopen the most recent close |
| `rex do undo_close` | The same, from a terminal |
| `rex do undo_history` | List what can come back, newest first |
| `rex do undo_clear` or Clear Closed Panes in the palette | Forget everything that could come back |

The history keeps the last 50 closes (or `REX_UNDO_HISTORY`), with each command line
as it was typed. If one held a secret, such as a token in a `curl` header, `undo_clear`
removes it.

## How It Works

Rex reports a close with an ID only, so `rex-undo/watcher.lua` runs alongside the server
(`rex do watcher.lua --all`, started by `init.lua`) and keeps a snapshot of every
session's layout and of each pane's folder, program, and command line. When something
closes, it records what went away in `~/.local/state/rex-undo/stack.jsonl`. The
`undo_close` action takes the newest entry and creates it again.

An agent's session ID comes from, in order:

1. The Claude hook, which records the conversation running in each pane.
2. The session file the agent keeps open (`lsof`), for agents with a `files` pattern.
3. Its command line, if it already named a session.

Without one, the agent's "continue the latest session here" command runs instead.

To add an agent, add a line to `agents.lua`, then run `./install.sh` again to restart the
watcher with it.

## Limits

- Programs start again; they aren't the same processes. Scrollback isn't restored.
- Environment variables set on the command line, as in `FOO=1 make`, are lost.
- A command reruns as it was, including one with side effects.
- Agent resume commands other than claude, codex, fx, opencode, and copilot come from
  their documentation and weren't run here.
- Closes are recorded only while the watcher runs. Its log is
  `~/.local/state/rex-undo/watcher.log`.

## Uninstall

```sh
./uninstall.sh
```

This stops the watcher, removes the block and the hook, and deletes the history in
`~/.local/state/rex-undo`, since it holds command lines as they were typed. To update
rex-undo, run `./install.sh` again instead.
