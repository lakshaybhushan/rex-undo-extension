# rex-undo

Reopen the pane, tab, or session you just closed in [Rex](https://www.superlogical.com/rex),
with whatever was running in it. Press `cmd+shift+t`.

- A shell comes back in the same folder.
- A command comes back running, with the command line it was started with.
- An agent comes back in the same conversation: `claude --resume ID`, `codex resume ID`,
  `fx --resume-ID`, and 19 others listed in [`rex-undo/agents.lua`](rex-undo/agents.lua).

Panes return to the same side of the same split, tabs to the same place in the tab bar,
and sessions with every tab.

## Install

rex-undo runs on macOS and Linux. It needs Rex, and `jq` for the Claude hook:

- Rex. `install.sh` looks for the `rex` CLI on `PATH`, then inside the app bundle.
- `flock`, on Linux only. It comes with util-linux, which every common distribution
  installs.
- `jq`, optional. Without it, the install skips the Claude hook and Claude panes reopen
  with `--continue` instead of the exact conversation.

```sh
./install.sh
```

`install.sh` adds a block to `~/.config/rex/init.lua`, adds a Claude Code `SessionStart`
hook to `~/.claude/settings.json` after copying it to `settings.json.rex-undo.bak`, and
reloads the Rex config. The block and the hook both name this folder by absolute path,
so keep it where it is. Running the script again is safe: it replaces the old block and
hook, restarts the watcher on the new code, and keeps the history. Until you run it after
a move, Rex logs `rex-undo: not loaded` and loads the rest of the config.

| Variable | Default | Does |
| --- | --- | --- |
| `REX_UNDO_KEY` | `cmd+shift+t` | Key that reopens the most recent close |
| `REX_UNDO_HISTORY` | `50` | Closes to keep |
| `XDG_CONFIG_HOME`, `XDG_STATE_HOME` | Standard XDG paths | Where `init.lua` and the history live |

```sh
REX_UNDO_HISTORY=200 ./install.sh
```

## Use

| Do | How |
| --- | --- |
| Reopen the most recent close | `cmd+shift+t`, or Reopen Closed Pane in the palette |
| Do the same from a terminal | `rex do undo_close` |
| List what can come back, newest first | `rex do undo_history`, or Show Closed Panes in the palette |
| Forget all of it | `rex do undo_clear`, or Clear Closed Panes in the palette |

Each press takes the newest close off the history. If one can't come back, rex-undo
drops it and stops there; press again to go further back.

The history keeps the last 50 closes, or `REX_UNDO_HISTORY`, with each command line as
it was typed. That includes anything typed into one, such as a token in a `curl` header,
so `undo_clear` empties both the history and the watcher's log, which names each close.
Both files are readable only by you.

## How it works

Rex reports a close as an ID and nothing else, which is why there is a watcher.
[`rex-undo/watcher.lua`](rex-undo/watcher.lua) runs alongside the server
(`rex do watcher.lua --all`, started by `init.lua`) and keeps a snapshot of every
session's layout, plus each pane's folder, program, and command line. When something
closes, it appends what went away to `~/.local/state/rex-undo/stack.jsonl`. The
`undo_close` action takes the newest entry and creates it again, in its old split or tab
position. That snapshot is also how a pane returns to the right side of the split rather
than opening in a fresh one.

IDs of what it recreated go into `remap.json`, so reopening a pane from a restored tab
later lands back in that tab.

An agent's session ID comes from, in order:

1. The Claude hook, which records the conversation running in each pane.
2. The session file the agent keeps open, found with `lsof`, for agents that have a
   `files` pattern.
3. Its command line, if it already named a session.

Without an ID, the agent's "continue the latest session here" command runs instead, such
as `claude --continue` or `codex resume --last`.

## Agents

`agents.lua` has 22 entries. The resume commands for claude, codex, fx, opencode, and
copilot were checked against each tool's `--help`; the rest come from their documentation
and weren't run here. A program that isn't listed is rerun with the command line it was
started with. So is a program that only shares an agent's name: a script of your own,
such as `python3 claude.py`, or fx the JSON viewer and amp the editor.

To add one, add an entry to `agents.lua`, then run `./install.sh` again so the watcher
restarts with it.

## Limits

- Programs start again; they are not the same processes. rex-undo doesn't restore
  scrollback.
- Environment variables set on the command line, as in `FOO=1 make`, are lost.
- A command reruns as it was, including one with side effects.
- A pane whose folder no longer exists, such as a removed worktree, comes back as a plain
  shell in `~`, without its command.
- An agent resumes without the flags it was started with, such as `--model` or a
  permission mode.
- A command is typed into the new shell, so a tab or other control character in it can
  come back changed, and a command kept out of shell history with a leading space goes
  into history.
- fx, amp, goose, and pi share their names with other tools, so one of them counts as
  the agent only when it reports itself to Rex or rex-undo finds its session. Otherwise
  its command reruns as typed, so such an agent can come back in a new session.
- rex-undo records closes only while the watcher runs. Its log is
  `~/.local/state/rex-undo/watcher.log`.
- The watcher keeps the code it started with. Run `./install.sh` after pulling changes,
  or the old code stays running.

## Tests

```sh
sh tests/run.sh
```

The tests run against a temporary state directory and home, and need `luajit` and `jq`.
[`STATE_MACHINES.md`](STATE_MACHINES.md) records the state each part keeps and the bugs
the tests cover.

## Uninstall

```sh
./uninstall.sh
```

`uninstall.sh` stops the watcher, removes the block and the hook, and deletes
`~/.local/state/rex-undo`, since the history holds command lines as they were typed. To
update rex-undo, run `./install.sh` again instead; it keeps the history.

## Contributing

Issues and pull requests are welcome. Run `sh tests/run.sh` before sending a change.

## License

MIT. See [LICENSE](LICENSE).
