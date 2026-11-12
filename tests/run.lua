-- Regression tests. Run with: sh tests/run.sh
local root = arg[1]
package.path = root .. "/tests/?.lua;" .. package.path
local mock = require("mock")
local lib = dofile(root .. "/rex-undo/lib.lua")
local failed = 0
local function test(name, fn)
  os.execute("rm -rf " .. lib.state_dir)
  mock.timers, mock.views, mock.sessions, mock.view_error, mock.on_call, mock.block_call = {}, {}, {}, nil, nil, nil
  mock.list_fail = nil
  local ok, err = pcall(fn)
  print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or (": " .. tostring(err))))
  if not ok then failed = failed + 1 end
end

local SID = "session:1"
local function view(blocks)
  local bs, layout = {}, nil
  for _, id in ipairs(blocks) do
    bs[#bs + 1] = { block_id = id, flavor = "x.y", creator_name = "x" }
    local leaf = { block_id = id }
    layout = layout and { split = { direction = "horizontal", ratio = 0.5, before = layout, after = leaf } } or leaf
  end
  return { session_id = SID, label = "s", active_window_id = "window:1", windows = {
    { window_id = "window:1", layers = { { kind = "tiled", layout = layout, blocks = bs } } } } }
end

-- Loads a fresh watcher and lets it take its first snapshot of SID.
local function start_watcher(blocks, v)
  mock.sessions[SID] = true
  mock.views[SID] = v or view(blocks)
  mock.handlers = {}
  os.execute("mkdir -p " .. lib.claude_dir)
  local env_dir = root .. "/rex-undo"
  local f = assert(loadfile(env_dir .. "/watcher.lua"))
  setfenv(f, setmetatable({ os = setmetatable({ getenv = function(k)
    if k == "REX_UNDO_DIR" then return env_dir end
    return os.getenv(k)
  end }, { __index = os }) }, { __index = _G }))
  f()
  mock.run_timers()
end

test("a failed view read doesn't record the live session as closed", function()
  start_watcher({ "block:a", "block:b" })
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.views[SID] = nil -- the session is still listed, but the read fails
  mock.run_timers()
  assert(#lib.read_stack() == 0, "recorded " .. tostring((lib.read_stack()[1] or {}).kind))
  mock.views[SID] = view({ "block:a" })
  mock.run_timers() -- the retry
  local s = lib.read_stack()
  assert(#s == 1 and s[1].kind == "panes", "expected one pane entry, got " .. #s)
end)

test("a session that is gone is still recorded", function()
  start_watcher({ "block:a" })
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.sessions[SID], mock.views[SID] = nil, nil
  mock.run_timers()
  local s = lib.read_stack()
  assert(#s == 1 and s[1].kind == "session", "expected a session entry")
end)

test("the watcher marks a close as settling until it's recorded", function()
  start_watcher({ "block:a", "block:b" })
  mock.handlers.block_closed({ session_id = SID }, {})
  assert(lib.exists(lib.settling_path), "no settling marker while the close is pending")
  mock.views[SID] = view({ "block:a" })
  mock.run_timers()
  assert(not lib.exists(lib.settling_path), "the marker outlived the close")
  assert(#lib.read_stack() == 1, "the close wasn't recorded")
end)

test("a failed session list doesn't record the live session as closed", function()
  start_watcher({ "block:a", "block:b" })
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.views[SID], mock.list_fail = nil, true
  mock.run_timers()
  assert(#lib.read_stack() == 0, "recorded " .. tostring((lib.read_stack()[1] or {}).kind))
  mock.views[SID], mock.list_fail = view({ "block:a" }), nil
  mock.run_timers()
  local s = lib.read_stack()
  assert(#s == 1 and s[1].kind == "panes", "expected one pane entry, got " .. #s)
end)

test("a close seen first as a view change is still recorded", function()
  -- The watcher was busy; by the time it reads the view, block:b is gone.
  start_watcher({ "block:a", "block:b" })
  mock.views[SID] = view({ "block:a" })
  mock.handlers.session_view_changed({ session_id = SID }, {})
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.run_timers()
  local s = lib.read_stack()
  assert(#s == 1 and s[1].kind == "panes" and s[1].panes[1].block_id == "block:b", "got " .. #s .. " entries")
  -- The next close doesn't record block:b again.
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.views[SID] = view({})
  mock.views[SID].windows[1].layers[1].layout = nil
  mock.run_timers()
  for i = 2, #lib.read_stack() do
    for _, p in ipairs(lib.read_stack()[i].panes or {}) do assert(p.block_id ~= "block:b", "block:b recorded twice") end
  end
end)

test("a tab whose only pane moved or was detached isn't recorded as closed", function()
  local function two_tabs()
    local v = view({ "block:a" })
    local w2 = view({ "block:b" }).windows[1]
    w2.window_id = "window:2"
    v.windows[2] = w2
    return v
  end
  start_watcher(nil, two_tabs())
  mock.handlers.window_closed({ session_id = SID }, {})
  mock.views[SID] = view({ "block:a", "block:b" }) -- moved into window:1
  mock.run_timers()
  assert(#lib.read_stack() == 0, "moved pane recorded as a closed tab")
  mock.views[SID] = two_tabs()
  mock.handlers.session_view_changed({ session_id = SID }, {})
  mock.run_timers()
  mock.handlers.window_closed({ session_id = SID }, {})
  mock.views[SID] = view({ "block:a" })
  mock.on_call = function(method)
    if method == "session.list_blocks" then return { blocks = { { block_id = "block:a" }, { block_id = "block:b" } } } end
  end
  mock.run_timers()
  assert(#lib.read_stack() == 0, "detached pane recorded as a closed tab")
end)

local function load_undo()
  return dofile(root .. "/rex-undo/undo.lua").setup{ dir = root .. "/rex-undo", key = false, watcher = false }
end

-- Replies for the create calls, and which ones were made.
local function fake_creates()
  local made = {}
  mock.on_call = function(method)
    made[#made + 1] = method
    if method == "session.new_split" then return { block_ids = { "block:n" } } end
    if method == "session.new_window" then return { window_id = "window:n", block_ids = { "block:n" } } end
    if method == "session.create" then
      return { session_id = "session:n", initial_windows = { { window_id = "window:n", block_ids = { "block:n" } } } }
    end
    return {}
  end
  return made
end

local function pane_entry(sid, wid)
  return { kind = "panes", summary = "pane in " .. sid, session_id = sid, window_id = wid,
    panes = { { block_id = "block:a", block = {}, placement = {} } } }
end

test("an undo right after a close waits for it and reopens it", function()
  local undo = load_undo()
  mock.sessions[SID] = true
  lib.push(pane_entry(SID, "window:1")) -- the close before
  local f = io.open(lib.settling_path, "w"); f:write(tostring(os.time())); f:close()
  -- The watcher records the new close 0.3s later, then clears the marker.
  os.execute(string.format("(sleep 0.3; luajit %s/tests/push_many.lua %s new 1; rm -f %s) &", root, root, lib.settling_path))
  local r = undo.undo({})
  assert(r.message == "Couldn't reopen new1", "took the close before: " .. tostring(r.message or r.summary))
  assert(#lib.read_stack() == 1, "expected the close before still there")
end)

test("pressing again moves further back and ends at nothing to reopen", function()
  local undo = load_undo()
  fake_creates()
  mock.sessions[SID] = true
  mock.views[SID] = view({ "block:b" })
  lib.push(pane_entry(SID, "window:1"))
  lib.push({ kind = "bogus", summary = "broken" }) -- newest, and can't come back
  local r = undo.undo({})
  assert(not r.restored and r.message == "Couldn't reopen broken", "got " .. tostring(r.message))
  r = undo.undo({})
  assert(r.restored and r.summary == "pane in " .. SID, "expected the older pane back")
  r = undo.undo({})
  assert(not r.restored and r.message == "Nothing to reopen", "expected the end, got " .. tostring(r.message))
  assert(#lib.read_stack() == 0, "the broken entry came back")
end)

test("a restore that throws is dropped, not cycled", function()
  local undo = load_undo()
  mock.sessions[SID] = true
  mock.view_error = true
  lib.push(pane_entry(SID, "window:1"))
  local r = undo.undo({})
  assert(not r.restored and r.message:match("^Couldn't reopen"), "got " .. tostring(r.message))
  assert(#lib.read_stack() == 0, "the entry is still in the history")
end)

test("a failure that hits every entry costs one press, not the history", function()
  local undo = load_undo()
  mock.on_call = function() return nil end -- every create fails
  for i = 1, 5 do lib.push(pane_entry("session:gone" .. i, "window:old")) end
  local r = undo.undo({})
  assert(not r.restored, "reported a restore")
  assert(#lib.read_stack() == 4, "expected 4 entries left, got " .. #lib.read_stack())
end)

test("a restore that throws after creating something counts as reopened", function()
  local undo = load_undo()
  local creates = 0
  mock.on_call = function(method)
    if method == "session.create" then
      creates = creates + 1
      return { session_id = "session:n" } -- no initial_windows: the restore throws
    end
  end
  lib.push(pane_entry("session:gone1", "window:old"))
  lib.push(pane_entry("session:gone2", "window:old"))
  local r = undo.undo({})
  assert(r.restored, "reported as failed: " .. tostring(r.message))
  assert(creates == 1 and #lib.read_stack() == 1, "one press reopened " .. creates .. " things")
end)

test("a failed lookup reopens nothing and keeps the entry", function()
  local undo = load_undo()
  local made = fake_creates()
  mock.sessions[SID], mock.list_fail = true, true
  lib.push(pane_entry(SID, "window:1"))
  local r = undo.undo({ session_id = SID })
  assert(not r.restored and r.message:match("Try again"), "got " .. tostring(r.message))
  assert(#made == 0, "created " .. tostring(made[1]))
  assert(#lib.read_stack() == 1, "the entry was dropped")
  assert(next(lib.read_remap()) == nil, "wrote a remap")
end)

test("a pane whose folder is gone comes back as a shell, without its command", function()
  local undo = load_undo()
  local sent = {}
  mock.on_call = function(method, args)
    if method == "session.new_split" then
      sent[#sent + 1] = args.layout.block.options
      return { block_ids = { "block:n" } }
    end
    return {}
  end
  mock.sessions[SID] = true
  mock.views[SID] = view({ "block:b" })
  local e = pane_entry(SID, "window:1")
  e.panes[1].block = { options = { cwd = "/no/such/worktree", initial_input = "rm -rf build\n" } }
  lib.push(e)
  e = pane_entry(SID, "window:1")
  e.panes[1].block = { options = { cwd = root, initial_input = "make\n" } }
  lib.push(e)
  assert(undo.undo({}).restored and undo.undo({}).restored, "didn't reopen both")
  assert(sent[1].initial_input == "make\n", "dropped the command of a pane whose folder exists")
  assert(sent[2].initial_input == nil, "reran " .. tostring(sent[2].initial_input) .. " without its folder")
end)

test("a session entry for a session that's still open isn't copied", function()
  local undo = load_undo()
  local made = fake_creates()
  mock.sessions[SID] = true
  lib.push({ kind = "session", summary = "session in s", session_id = SID,
    windows = { { window_id = "window:1", layers = { { kind = "tiled", layout = { block = {} }, block_ids = { "block:a" } } } } } })
  local r = undo.undo({})
  assert(not r.restored, "restored a copy")
  for _, m in ipairs(made) do assert(m ~= "session.create", "created a copy") end
end)

test("a pane whose session is gone reopens in the session you're in", function()
  local undo = load_undo()
  local made = fake_creates()
  mock.sessions[SID] = true
  mock.views[SID] = view({ "block:b" })
  lib.push(pane_entry("session:gone", "window:old"))
  local r = undo.undo({ session_id = SID })
  assert(r.restored and r.session_id == SID, "reopened in " .. tostring(r.session_id))
  for _, m in ipairs(made) do assert(m ~= "session.create", "created a new session") end
end)

test("with no current session, it still gets a session of its own", function()
  local undo = load_undo()
  fake_creates()
  lib.push(pane_entry("session:gone", "window:old"))
  local r = undo.undo({})
  assert(r.restored and r.session_id == "session:n", "got " .. tostring(r.session_id))
end)

test("two processes pushing at once lose nothing", function()
  lib.ensure_dirs()
  local cmd = "luajit %s/tests/push_many.lua %s %s 40"
  os.execute(string.format("(" .. cmd .. " & " .. cmd .. " & wait)", root, root, "a", root, root, "b"))
  local n = #lib.read_stack()
  assert(n == 80, "expected 80 entries, got " .. n)
end)

test("a lock in use is waited for, and a stale one is taken over", function()
  lib.ensure_dirs()
  local push = string.format("luajit %s/tests/push_many.lua %s x 1", root, root)
  os.execute("mkdir " .. lib.lock_path)
  -- Held for longer than the old ~4s takeover, and kept fresh so it isn't stale.
  os.execute("(" .. push .. " &) ; for i in 1 2 3 4 5 6; do sleep 1; touch " .. lib.lock_path .. "; done")
  assert(#lib.read_stack() == 0, "pushed without the lock")
  assert(lib.exists(lib.lock_path), "removed a lock in use")
  os.execute("rmdir " .. lib.lock_path .. "; sleep 1")
  assert(#lib.read_stack() == 1, "didn't push once the lock was free")
  os.execute("mkdir " .. lib.lock_path .. " && touch -t 202001010000 " .. lib.lock_path)
  os.execute(push)
  assert(#lib.read_stack() == 2, "a stale lock blocked the push")
end)

test("a short write keeps the history", function()
  for i = 1, 30 do lib.push({ kind = "panes", summary = string.rep("x", 200) .. i }) end
  -- A 2 KB file-size limit stands in for a full disk.
  os.execute(string.format("sh -c \"trap '' XFSZ; ulimit -f 4; luajit %s/tests/push_many.lua %s y 1\" 2>/dev/null", root, root))
  assert(#lib.read_stack() == 30, "history is now " .. #lib.read_stack() .. " entries")
end)

-- One terminal pane, block:t, running `fg`, beside a second pane; close block:t
-- and return the command its entry would type.
-- `app` is what the program reported to Rex as, if anything.
local function closed_terminal_input(fg, app)
  local T = "com.superlogical.terminal"
  local function tview(ids)
    local v = view(ids)
    for _, b in ipairs(v.windows[1].layers[1].blocks) do
      if b.block_id == "block:t" then b.creator_name, b.flavor = T, T .. ".shell" end
    end
    return v
  end
  mock.block_call = function(_, method)
    if method == "process" then return { foreground = fg } end
    if method == "program_status" and app then
      return { records = { { owner = { pid = fg.pid }, effective_app = app } } }
    end
  end
  start_watcher(nil, tview({ "block:t", "block:b" }))
  mock.handlers.block_closed({ session_id = SID }, {})
  mock.views[SID] = view({ "block:b" })
  mock.run_timers()
  local e = lib.read_stack()[1]
  return e and e.panes[1].block.options.initial_input
end

local function claude_hook_record(rex_pid, transcript)
  local f = assert(io.open(lib.claude_dir .. "/t.json", "w"))
  f:write(string.format('{["session_id"]="1234abcd-0000",["transcript_path"]=%q,["rex_pid"]=%d}', transcript, rex_pid))
  f:close()
end

test("a command reruns with its quoting", function()
  local p = io.popen([[perl -e 'sleep 20' 'a b' "it's" '' & echo $!]])
  local pid = tonumber(p:read("*l")); p:close()
  local ok, input = pcall(closed_terminal_input, { pid = pid, name = "perl", argv0 = "perl" })
  os.execute("kill " .. pid)
  assert(ok, input)
  local want = [[perl -e 'sleep 20' 'a b' 'it'\''s' '']] .. "\n"
  assert(input == want, "got " .. tostring(input))
end)

test("a program that renamed itself reruns by its title", function()
  -- npm sets its title to `npm run dev`, which the kernel then reports as argv.
  local p = io.popen([[perl -e '$0 = "npm run dev"; sleep 20' & echo $!]])
  local pid = tonumber(p:read("*l")); p:close()
  os.execute("sleep 0.3")
  local ok, input = pcall(closed_terminal_input, { pid = pid, name = "perl", argv0 = "perl" })
  os.execute("kill " .. pid)
  assert(ok, input)
  assert(input == "npm run dev\n", "got " .. tostring(input))
end)

test("npm gets back the -- its title dropped", function()
  -- `npm run dev -- -H localhost` titles itself `npm run dev -H localhost`.
  local p = io.popen([[perl -e '$0 = "npm run dev -H localhost"; sleep 20' & echo $!]])
  local pid = tonumber(p:read("*l")); p:close()
  os.execute("sleep 0.3")
  local ok, input = pcall(closed_terminal_input, { pid = pid, name = "perl", argv0 = "perl" })
  os.execute("kill " .. pid)
  assert(ok, input)
  assert(input == "npm run dev -- -H localhost\n", "got " .. tostring(input))
end)

test("a program that only shares an agent's name reruns as itself", function()
  local function input(fg, app)
    lib.clear()
    fg.pid = 999999
    return closed_terminal_input(fg, app)
  end
  local got = input({ name = "fx", argv0 = "fx" })
  assert(got == "fx\n", "fx the JSON viewer came back as " .. tostring(got))
  got = input({ name = "fx", argv0 = "fx" }, "fx")
  assert(got == "fx -c\n", "fx the agent, reported to Rex, came back as " .. tostring(got))
  got = input({ name = "python3", argv0 = "python3", script = "/Users/x/project/claude.py" })
  assert(got == "python3\n", "a script named claude.py came back as " .. tostring(got))
  got = input({ name = "node", argv0 = "node", script = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js" })
  assert(got == "codex resume --last\n", "installed codex came back as " .. tostring(got))
end)

test("a Claude hook record from another process isn't used", function()
  os.execute("mkdir -p " .. lib.claude_dir)
  claude_hook_record(999998, root .. "/README.md")
  local input = closed_terminal_input({ pid = 999999, name = "claude", argv0 = "claude" })
  assert(input == "claude --continue\n", "got " .. tostring(input))
end)

test("the Claude hook record of the running process is used", function()
  os.execute("mkdir -p " .. lib.claude_dir)
  claude_hook_record(999999, root .. "/README.md")
  local input = closed_terminal_input({ pid = 999999, name = "claude", argv0 = "claude" })
  assert(input == "claude --resume 1234abcd-0000\n", "got " .. tostring(input))
end)

test("remap merges with what's there and keeps only IDs the stack names", function()
  lib.push({ kind = "panes", session_id = "session:old", window_id = "window:w" })
  lib.write_remap({ ["session:old"] = "session:mid", ["block:gone"] = "block:new" })
  local m = lib.read_remap()
  assert(m["session:old"] == "session:mid" and m["block:gone"] == "block:new", "lost a mapping below the limit")
  local max = lib.remap_max
  lib.remap_max = 0 -- prune on the next write
  local ok, err = pcall(lib.write_remap, { ["session:mid"] = "session:new" }) -- a second undo, with its own map
  lib.remap_max = max
  assert(ok, err)
  m = lib.read_remap()
  assert(m["session:old"] == "session:new", "chain not followed: " .. tostring(m["session:old"]))
  assert(m["block:gone"] == nil and m["session:mid"] == nil, "unreferenced IDs kept")
end)

test("the history keeps the newest 50, one line each", function()
  for i = 1, 55 do lib.push({ kind = "panes", summary = "e" .. i, block = { options = { initial_input = "ls\n" } } }) end
  local s = lib.read_stack()
  assert(#s == 50 and s[1].summary == "e6" and s[50].summary == "e55", "kept " .. #s .. " from " .. tostring((s[1] or {}).summary))
  local f = io.open(lib.stack_path); local text = f:read("*a"); f:close()
  assert(select(2, text:gsub("\n", "")) == 50, "an entry spans more than one line")
  assert(lib.pop().summary == "e55" and lib.pop().summary == "e54", "pop didn't take the newest")
  assert(#lib.read_stack() == 48, "pop removed more than one")
end)

test("the history limit set in setup applies to the watcher's pushes", function()
  local function setup(history)
    dofile(root .. "/rex-undo/undo.lua").setup{ dir = root .. "/rex-undo", key = false, watcher = false, history = history }
  end
  setup(3)
  for i = 1, 5 do lib.push({ kind = "panes", summary = "e" .. i }) end -- lib here is the watcher's copy
  local s = lib.read_stack()
  assert(#s == 3 and s[1].summary == "e3", "kept " .. #s)
  setup("lots") -- a bad value keeps the default instead of failing the config
  for i = 6, 60 do lib.push({ kind = "panes", summary = "e" .. i }) end
  assert(#lib.read_stack() == 50, "kept " .. #lib.read_stack())
end)

test("a history from an earlier version is carried over", function()
  lib.ensure_dirs()
  local f = io.open(lib.old_stack_path, "w")
  f:write(rex.json.encode({ { kind = "panes", summary = "old1" }, { kind = "panes", summary = "old2" } }))
  f:close()
  assert(#lib.read_stack() == 2, "didn't read the old file")
  assert(lib.pop().summary == "old2", "didn't pop the newest old entry")
  assert(not lib.exists(lib.old_stack_path), "the old file is still there")
  assert(#lib.read_stack() == 1 and lib.read_stack()[1].summary == "old1", "lost the older entry")
end)

test("a line that doesn't decode is skipped, not the whole history", function()
  lib.push({ kind = "panes", summary = "good" })
  local f = io.open(lib.stack_path, "a"); f:write("{garbage\n"); f:close()
  assert(#lib.read_stack() == 1, "read " .. #lib.read_stack())
  assert(lib.pop().summary == "good", "the bad line hid the good one")
  assert(lib.pop() == nil, "expected an empty history")
end)

test("clear empties the history and says how much it forgot", function()
  local undo = load_undo()
  assert(undo.clear() == "Nothing to clear", "expected nothing to clear")
  lib.push(pane_entry(SID, "window:1"))
  lib.push(pane_entry(SID, "window:1"))
  lib.write_remap({ ["block:a"] = "block:b" })
  local log = io.open(lib.state_dir .. "/watcher.log", "w"); log:write("recorded pane in s: curl -H 'Authorization: x'\n"); log:close()
  assert(undo.clear() == "Cleared 2 closed items", "wrong count")
  log = io.open(lib.state_dir .. "/watcher.log"); local text = log:read("*a"); log:close()
  assert(text == "", "the log still has the command lines")
  assert(#lib.read_stack() == 0, "the history is still there")
  assert(next(lib.read_remap()) == nil, "the ID map is still there")
  assert(undo.history() == "Nothing to reopen", "history still lists entries")
end)

os.exit(failed == 0 and 0 or 1)
