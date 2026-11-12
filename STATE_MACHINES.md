# rex-undo state machines

What state each part keeps, what must hold, and how it moves. "Reachable" bugs
cite the code path; "Fixed" ones have a regression test in `tests/` (run
`sh tests/run.sh`).

Concurrency model: the watcher (`rex do watcher.lua --all`) runs its handlers
and timers one at a time. The `undo_close` action runs in the Rex server, a
separate process. They share only files under `~/.local/state/rex-undo/`.

## 1. Watcher supervisor (`bin/rex-undo-watch`)

| State | Meaning |
| --- | --- |
| Absent | no copy holds `watcher.lock` |
| Running | one copy holds the lock and loops over `rex do watcher.lua` |
| Backoff | `rex do` exited within 10s; `fails` += 1, sleep 2s |
| GaveUp | 30 fast failures in a row; exits, freeing the lock |

| From | Event | To |
| --- | --- | --- |
| Absent | config load starts a copy | Running |
| Running | second copy starts | second copy exits 75 (lock held), or 0 (live pre-lock copy in `watcher.pid`) |
| Running | `rex do` ran > 10s and exited | Running (fails = 0) |
| Running | `rex do` exited in ≤ 10s | Backoff → Running, or GaveUp at 30 |
| any | SIGTERM/INT/HUP, install, uninstall | Absent (pidfile removed by trap, lock freed by kernel); install's config reload then starts a new copy |

Invariant: at most one watcher runs. Otherwise every close is recorded once
per copy.

- **Fixed (high): duplicate watchers.** The old check read the pidfile, then
  `rm -f` and `set -C` created it again. Two copies that both found a stale
  pidfile could each remove the other's new file, so both ran.
  `tests/supervisor_test.sh` started 12 copies at once and got 3 to 6 watchers.
  The fix is a `lockf` kernel lock, which can't go stale. The pidfile is kept
  for `uninstall.sh` and to recognize a copy started before this change.

## 2. Per-session close tracker (`watcher.lua`: `views`, `closing`)

| State | Data |
| --- | --- |
| Unknown | no `views[sid]` |
| Snapshotted | `views[sid]` = last `session.view` |
| Settling | `closing[sid] = { view, destroyed, timer, tries }` |
| Gone | `views[sid]` cleared, blocks forgotten |

| From | Event | To |
| --- | --- | --- |
| Unknown | `session_created`, `session_view_changed`, startup scan | Snapshotted |
| Unknown | close event | Unknown (ignored: nothing to compare with) |
| Snapshotted | view change, every block still there | Snapshotted (snapshot replaced) |
| Snapshotted | view change with a block missing | Settling (snapshot kept; the close event may come later or not at all) |
| Snapshotted | `block_closed` / `window_closed` | Settling (timer 0.4s) |
| Settling | another close event | Settling (timer restarted; `destroyed` is sticky) |
| Settling | view change | Settling (`refresh` skips it, so the snapshot stays pre-close) |
| Settling | timer, fresh view read | records panes/tabs that went away, leaving out blocks still in the session (moved, or detached per `session.list_blocks`) → Snapshotted on the fresh view |
| Settling | timer, `destroyed` or not listed | records a `session` entry → Gone |
| Settling | timer, view read failed, session listed or the list call failed | Settling again, up to 5 tries, then Snapshotted on the old view with nothing recorded (the next view change settles again) |

Invariants: a `session` entry means the session no longer exists. While
Settling, the snapshot is the layout before the close. A block is recorded
once: after recording, the snapshot is the view it was compared with.

- **Fixed (medium): live session recorded as closed.** `rex.session.view`
  returns `nil` on any error, including a timeout, and `finalize` treated `nil`
  as "session gone". Undo then created a copy of a session that still existed,
  and the real closed panes went unrecorded. Test: "a failed view read doesn't
  record the live session as closed". A failed `session.list` did the same
  (it read as "not listed"); it now counts as unknown and retries. Test: "a
  failed session list doesn't record the live session as closed".
- **Fixed (high): a moved or detached pane recorded as a closed tab.** Rex
  sends `window_closed` when a tab's last pane moves to another tab or is
  detached, and the tab was recorded whole, so undo duplicated a live pane and
  reran its command. Blocks still in the session are now left out, and a tab
  with none left isn't recorded. Test: "a tab whose only pane moved or was
  detached isn't recorded as closed".
- **Fixed (high): closes lost when the watcher fell behind.** `refresh` reads
  the view as it is now, so a view change handled after the close replaced
  the snapshot with one that already lacked the pane, and the close had
  nothing to compare with. A view change with a block missing now settles like
  a close. Test: "a close seen first as a view change is still recorded".
- **Fixed (medium): a close recorded twice.** If the read after recording
  failed, the snapshot stayed pre-close and the next close recorded the same
  panes again. Covered by the test above.

## 3. Per-terminal program (`watcher.lua`: `blocks[bid]`)

| State | Data |
| --- | --- |
| Shell | `fg` nil or a shell (no `script`) |
| Program | `fg` is non-shell, with `args` from `ps` |
| Agent | Program matched in `agents.lua`, with `session_id` from the hook record → `lsof` → `query`, or none |
| JustExited | `fg` is a shell, `prev_fg` is an agent, `fg_at` ≤ 3s ago |

Transitions come from `process_changed`, `title_changed`,
`program_status_changed`, and the 5-second probe. A new pid moves `fg` to
`prev_fg`. The same pid merges into `fg`, keeping what was found before.

At close time, `block_spec` maps Shell → plain shell, Program → its argv,
Agent → `resume {id}` / argv naming a session / `continue`, and JustExited →
the previous agent.

- **Fixed (low): commands rerun without their quoting.** `args` came from
  `ps -o args=`, which joins argv with spaces, so `grep "a b" f` reran as
  `grep a b f`. It now comes from the kernel (`bin/rex-undo-argv`, via
  `KERN_PROCARGS2`) and each word is quoted again; `ps` is the fallback. Test:
  "a command reruns with its quoting".
- **Fixed (high, regression of the above): a program that renamed itself came
  back unrunnable.** npm, puma, and others write their title over argv, so the
  kernel reports `npm run dev` as one word followed by empty ones (or the
  environment), which reran as `'npm run dev' '' '' ''`. When the first word
  has a space or every other word is empty, the title is rerun as typed. Test:
  "a program that renamed itself reruns by its title".
- **Fixed (low): a stale hook record resumes the wrong conversation.** The
  record for a pane was used whichever Claude wrote it, so if a later Claude's
  hook didn't fire, undo resumed the earlier conversation. The hook now records
  `rex_pid` (Claude's pid), and the watcher uses the record only when that is
  the foreground process or in its process group. Otherwise, and for records
  from before this change, it falls back to `lsof`, then `--continue`. Tests:
  "a Claude hook record from another process isn't used" and "... of the
  running process is used".

## 4. Undo stack entry (`stack.jsonl`, `remap.json`)

Browser semantics: each press takes the newest close off the history and
reopens it. A close that can't come back is dropped and the press ends with
"Couldn't reopen …", so pressing repeatedly always moves further back and ends
at "Nothing to reopen". If a call that checks whether a session or tab exists
fails, nothing is created and the entry goes back on top ("Try again"). A
restore that throws after creating something counts as reopened. A `session`
entry for a session that still exists is dropped, not copied. A tab or pane whose session is gone reopens in the session
the press came from (`ctx.session_id`), as a browser reopens a tab in the
current window. A new session is made only for a closed session, or when
there's no current session (for example `rex do undo_close` with none).

| State | Where |
| --- | --- |
| Recorded | top of `stack.jsonl` |
| InFlight | popped by `undo_close`, not in the file |
| Restored | gone from the stack; old → new IDs in `remap.json` |
| Dropped | restore failed; gone, logged, named in the result's `skipped` / message |
| Evicted | pushed past 50 entries; dropped |

| From | Event | To |
| --- | --- | --- |
| — | watcher `record` | Recorded |
| Recorded | 50 newer entries | Evicted |
| Recorded | `undo_close` | InFlight |
| InFlight | restore returns IDs, or throws after creating something | Restored (press ends) |
| InFlight | an existence check's call fails, nothing created | Recorded again, on top (press ends) |
| InFlight | restore returns nil, throws, or kind unknown, nothing created | Dropped (press ends; remap is kept) |
| — | stack empty | press ends with "Nothing to reopen" |

Invariants: a press handles exactly one entry, so a failure that hits every
entry costs one entry, not the history, and one press reopens at most one
thing. Only an entry whose checks couldn't run goes back, and on top, so
presses can't cycle through the stack. Every change to `stack.jsonl` is a whole
read-change-write under `stack.lock`, written to a temp file whose write is
checked before it replaces the file.

`stack.jsonl` holds one entry per line, oldest first, so a push appends a line
and a pop decodes only the last one; a line that doesn't decode is skipped. A
`stack.json` from an earlier version (one JSON array) is read in its place and
removed on the first write.

- **Fixed (performance): each change decoded the whole history.** Push and pop
  decoded and re-encoded all 50 entries, and each press read the history a
  second time to prune the remap. In Rex, with 50 ten-tab sessions (500 KB),
  that was 24 ms per recorded close and ~56 ms of file work per press, and it
  started a `mkdir -p` process on every change. Now: 4.4 ms and ~8 ms; most of
  what's left is starting `mkdir` and `rmdir` for the lock (~1.9 ms each).
  Tests: "the history keeps the newest 50, one line each", "a history from an
  earlier version is carried over", "a line that doesn't decode is skipped".

- **Fixed (high): presses never ended, and spawned stray sessions.** A failed
  entry was moved to the bottom and came back again, so the history never
  emptied. A pane or tab whose session was gone came back in a brand-new
  session with a server-made name (`sparkling-sierra`, `dawn-moor`); closing
  that session recorded it, so the next press brought it back, over and over.
  Seen in `watcher.log`: `session in sparkling-sierra` recorded five times in
  40 seconds. Tests: "pressing again moves further back and ends at nothing to
  reopen", "a restore that throws is dropped, not cycled", "a pane whose
  session is gone reopens in the session you're in", "with no current session,
  it still gets a session of its own".
- **Fixed (high): entry lost when a restore throws.** Superseded by the item
  above: a throw is now caught and treated as a failed restore (dropped,
  reported), and the remap of anything already created is still written.
- **Fixed (high, regression of the above): one press emptied the history.**
  A failed entry was dropped and the same press moved on, so a failure that
  hit every entry (server busy, an API change) dropped all 50. When each
  restore created a session and then threw, it also made 50 sessions. A press
  now handles one entry. Tests: "a failure that hits every entry costs one
  press, not the history", "pressing again moves further back …".
- **Fixed (medium, regression of the above): two things reopened on one
  press.** A restore that created a tab and then threw (in `move_window`, say)
  was reported as dropped, and the press went on to reopen the next entry
  too. Test: "a restore that throws after creating something counts as
  reopened".
- **Fixed (high): a failed call made a copy of something still open.**
  `session_exists` and `window_exists` read a failed call as "gone", so undo
  created a stray session or tab and remapped the live ID to it for later
  undos. A `session` entry for a live session was also copied. Tests: "a
  failed lookup reopens nothing and keeps the entry", "a session entry for a
  session that's still open isn't copied".
- **Fixed (medium): lost updates between processes.** The watcher's push and
  undo's pop/re-push read, changed, and wrote `stack.jsonl` with no lock. A
  close recorded while undo ran could be overwritten. `lib.locked` now wraps
  them with an atomic `mkdir` lock. Test: "two processes pushing at once lose
  nothing".
- **Fixed (high): the lock let three processes in.** After ~4s of waiting it
  ran without the lock and then removed the holder's, letting a third in. It
  now never runs without the lock: it removes the lock only when it's over 5s
  old (a holder takes milliseconds), and gives up with an error after 10s.
  A holder stalled for over 5s can still lose it. Test: "a lock in use is
  waited for, and a stale one is taken over".
- **Fixed (high): a short write emptied the history.** `write_raw` didn't
  check the write, so on a full disk a cut-off `stack.jsonl` replaced the good
  one, read back as empty, and the next push left one entry. Test: "a short
  write keeps the history".
- **Fixed (low): `remap.json` had no lock and never shrank.** Two undos at
  once (if the server runs actions in parallel, which isn't documented) could
  drop each other's mappings. `write_remap` now merges into the file under the
  stack lock. Once it holds more than 100 IDs (`remap_max`), it keeps only old
  IDs that some stack entry still names and points each straight at the
  newest ID. That reads the whole history, so it isn't done on every press.
  Test: "remap merges with what's there and keeps only IDs the stack names".

Invariant: `remap.json` holds at most about 100 keys plus one press's worth.
A value may be another key; `lib.resolve` follows the chain to the newest ID.

## 5. Claude hook record (`claude/<block>.json`)

Absent → Recorded (SessionStart in a pane with a tty, not a subagent; holds
`rex_pid`) → Trusted while `rex_pid` is the pane's foreground Claude →
Overwritten (next SessionStart in that pane) → Deleted (older than 14 days, at
watcher start). Written via temp file + `mv`, so readers never see half a file.

## 6. Install

NotInstalled ⇄ Installed by `install.sh` / `uninstall.sh`. Both are idempotent.
Partial (one of the two markers) is detected by uninstall and left to the user
rather than running `sed` to the end of the file. `install.sh` stops a running
supervisor before it reloads the config, so the reload starts one on the new
code, and reports whether it did. `uninstall.sh` stops it, removes the block
and hook, and deletes the state folder (history, remap, Claude records, log).

- **Fixed (medium): a reinstall or update kept the old watcher.** The new
  supervisor found the lock held and exited, so the old code kept running,
  and after a move it ran a path that no longer existed, failed 30 times, and
  gave up. Install now stops it first (`lib/watcher.sh`), waiting until the
  lock is free. It sends TERM before ending the child, so the supervisor
  can't start another `rex do` in between.
