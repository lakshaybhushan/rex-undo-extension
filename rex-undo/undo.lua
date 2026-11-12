-- rex-undo, loaded from init.lua:
--
--   dofile("/path/to/rex-undo/undo.lua").setup{
--     dir = "/path/to/rex-undo",
--     rex = "/path/to/rex",        -- the CLI that runs the watcher
--     key = "cmd+shift+t",         -- false to bind nothing
--     history = 50,                -- closes to keep
--   }

local M = {}
local lib

-- Calls into a session work only on a connection attached to it, and the
-- closed thing may have lived in a session other than the one asking.
-- session.attach adds one session without changing the caller's other events.
local attached = {}
local function attach(sid)
  if not attached[sid] then
    rex.call("session.attach", { session_id = sid })
    attached[sid] = true
  end
end

-- Things this press created, so a restore that throws halfway still counts as
-- reopened rather than failed (and the press doesn't go on to reopen another).
local created = 0

-- A failed call (a timeout, say) says nothing about whether something exists.
-- Taking it as "gone" would make a copy of a session or tab that's still open,
-- so the press stops and the entry goes back for the next one.
local RETRY = {}
local function answer(v)
  if v == nil then error(RETRY, 0) end
  return v
end

local function session_exists(sid)
  if not sid then return false end
  local list = answer(rex.call("session.list"))
  for _, s in ipairs(list.sessions or {}) do
    if s.session_id == sid then
      attach(sid)
      return true
    end
  end
  return false
end

-- Asked only of a session that exists, so a failed read is a failed call.
local function window_exists(sid, wid)
  if not (sid and wid) then return false end
  local view = answer(rex.session.view{ session_id = sid })
  for _, w in ipairs(view.windows or {}) do
    if w.window_id == wid then return true end
  end
  return false
end

-- Map each old block ID to the new one, both in layout order.
local function remember_blocks(map, old_ids, new_ids)
  for i, old in ipairs(old_ids or {}) do
    if new_ids and new_ids[i] then map[old] = new_ids[i] end
  end
end

local function split_layers(w)
  local tiled, floating = nil, {}
  for _, l in ipairs(w.layers or {}) do
    if l.kind == "floating" then
      floating[#floating + 1] = l
    elseif not tiled then
      tiled = l
    end
  end
  if not tiled then tiled = table.remove(floating, 1) end
  return tiled, floating
end

local function add_floating(map, sid, wid, floating)
  for _, l in ipairs(floating) do
    local r = rex.session.new_layer{
      session_id = sid, window_id = wid, bounds = l.bounds, layout = l.layout,
    }
    if r then
      created = created + 1
      remember_blocks(map, l.block_ids, r.block_ids)
    end
  end
end

local function new_session(map, old_sid, label, windows)
  local requests, parts = {}, {}
  for i, w in ipairs(windows) do
    local tiled, floating = split_layers(w)
    if tiled then
      requests[#requests + 1] = { window_label = w.label, layout = tiled.layout }
      parts[#parts + 1] = { w = w, index = i, tiled = tiled, floating = floating }
    end
  end
  -- An empty table would be sent as {}, which session.create rejects.
  if #requests == 0 then return nil, "nothing to restore" end
  local r, err = rex.call("session.create", { label = label, initial_windows = requests })
  if not r and label then
    -- Another session may have the label by now.
    r, err = rex.call("session.create", { initial_windows = requests })
  end
  if not r then return nil, err end
  created = created + 1
  attach(r.session_id)
  if old_sid then map[old_sid] = r.session_id end
  for i, created in ipairs(r.initial_windows or {}) do
    local part = parts[i]
    created.index = part.index
    map[part.w.window_id] = created.window_id
    remember_blocks(map, part.tiled.block_ids, created.block_ids)
    add_floating(map, r.session_id, created.window_id, part.floating)
  end
  return r
end

local function new_window(map, sid, w, before_id)
  local tiled, floating = split_layers(w)
  if not tiled then return nil, "nothing to restore" end
  local r, err = rex.session.new_window{
    session_id = sid, window_label = w.label, layout = tiled.layout, focus = true,
  }
  if not r then return nil, err end
  created = created + 1
  map[w.window_id] = r.window_id
  remember_blocks(map, tiled.block_ids, r.block_ids)
  add_floating(map, sid, r.window_id, floating)
  if before_id and window_exists(sid, before_id) then
    rex.session.move_window{ session_id = sid, window_id = r.window_id, before_window_id = before_id }
  end
  return r
end

local function restore_session(map, e)
  -- Only a failed call in the watcher could record an open session as closed.
  if session_exists(e.session_id) then return nil, "it's still open" end
  local r, err = new_session(map, e.session_id, e.session_label, e.windows)
  if not r then return nil, err end
  local active
  for _, created in ipairs(r.initial_windows or {}) do
    if created.index == e.active_index then active = created end
  end
  if active then
    rex.session.focus_window{ session_id = r.session_id, window_id = active.window_id }
  end
  return r.session_id, active and active.window_id
end

-- The session the undo was asked from, if any.
local here

-- Like a browser, a tab or pane whose session is gone goes back into the
-- session you're in, not into a new session of its own. Its session's other
-- closes are mapped here too, so they gather in one place.
local function target_session(map, e)
  local sid = lib.resolve(map, e.session_id)
  if session_exists(sid) then return sid end
  if here and session_exists(here) then
    map[sid or e.session_id] = here
    return here
  end
end

local function restore_window(map, e)
  local sid = target_session(map, e)
  if sid then
    local r, err = new_window(map, sid, e.window, lib.resolve(map, e.before_window_id))
    if not r then return nil, err end
    return sid, r.window_id
  end
  local r, err = new_session(map, e.session_id, e.session_label, { e.window })
  if not r then return nil, err end
  return r.session_id, r.initial_windows[1].window_id
end

local function restore_pane(map, sid, wid, pane)
  local p = pane.placement or {}
  local layout = { block = pane.block }
  local r

  if p.floating and p.root then
    r = rex.session.new_layer{
      session_id = sid, window_id = wid, bounds = p.floating, layout = layout, focus = true,
    }
  end
  for _, anchor in ipairs((not r and p.anchors) or {}) do
    r = rex.session.new_split{
      session_id = sid, anchor_id = lib.resolve(map, anchor), direction = p.direction,
      side = p.side, ratio = p.ratio, layout = layout, focus = true,
    }
    if r then break end
  end
  if not r then
    r = rex.session.new_split{
      session_id = sid, window_id = wid, direction = p.direction or "horizontal",
      side = p.side or "after", layout = layout, focus = true,
    }
  end
  if r then created = created + 1 end
  if r and r.block_ids then map[pane.block_id] = r.block_ids[1] end
  return r
end

local function restore_panes(map, e)
  local sid = target_session(map, e)
  local wid = lib.resolve(map, e.window_id)
  if not (session_exists(sid) and window_exists(sid, wid)) then
    -- The tab is gone too, so the panes come back as a tab of their own.
    local first = e.panes[1]
    local w = {
      window_id = e.window_id,
      label = e.window_label,
      layers = { { kind = "tiled", layout = { block = first.block }, block_ids = { first.block_id } } },
    }
    local r, err
    if session_exists(sid) then
      r, err = new_window(map, sid, w)
      wid = r and r.window_id
    else
      r, err = new_session(map, e.session_id, e.session_label, { w })
      sid = r and r.session_id
      wid = r and r.initial_windows[1].window_id
    end
    if not r then return nil, err end
    for i = 2, #e.panes do restore_pane(map, sid, wid, e.panes[i]) end
    return sid, wid
  end
  local restored = 0
  for _, pane in ipairs(e.panes) do
    if restore_pane(map, sid, wid, pane) then restored = restored + 1 end
  end
  if restored == 0 then return nil, "couldn't place the pane" end
  return sid, wid
end

-- A pane whose folder is gone (a removed worktree, a path from an ssh session)
-- would open in ~ and rerun its command there, such as `rm -rf build`. It
-- comes back as a plain shell instead.
local function skip_missing_folders(v)
  if type(v) ~= "table" then return end
  local o = v.options
  if type(o) == "table" and o.initial_input and o.cwd and not lib.exists(o.cwd) then
    o.initial_input = nil
  end
  for _, x in pairs(v) do skip_missing_folders(x) end
end

local restorers = {
  session = restore_session,
  window = restore_window,
  panes = restore_panes,
}

-- Like a browser's Reopen Closed Tab: each press takes the newest close off
-- the history and reopens it. One that can't come back is dropped and the
-- press ends there, so pressing again moves further back and ends at "Nothing
-- to reopen", and a failure that hits every entry costs one, not the history.
-- A close the watcher is still settling isn't in the history yet. Wait for it
-- (up to ~1.5s), so an undo right after a close reopens that close.
local function wait_for_settling()
  for _ = 1, 30 do
    local f = io.open(lib.settling_path, "r")
    if not f then return end
    local t = tonumber(f:read("*a"))
    f:close()
    -- Older than 3s: left by a watcher that stopped mid-close.
    if not t or os.time() - t > 3 then return end
    rex.exec({ "sleep", "0.05" })
  end
end

function M.undo(ctx)
  attached = {}
  here = ctx and ctx.session_id
  wait_for_settling()
  local entry = lib.pop()
  if not entry then return { restored = false, message = "Nothing to reopen" } end
  local map = lib.read_remap()
  local restore = restorers[entry.kind]
  skip_missing_folders(entry)
  created = 0
  local ok, sid, wid = true, nil, "unknown entry kind " .. tostring(entry.kind)
  if restore then ok, sid, wid = pcall(restore, map, entry) end
  if not ok then sid, wid = nil, sid end
  -- Keep what came back before a failure, so later undos find it.
  lib.write_remap(map)
  local name = tostring(entry.summary or entry.kind)
  if sid or created > 0 then
    -- Show what came back. From the CLI this would need the app's Remote
    -- Control setting, so only do it for a key press or the command palette.
    if sid and ctx and ctx.client_id and (ctx.origin == "key" or ctx.origin == "palette") then
      pcall(rex.client.queue, "session.select", { session_id = sid, window_id = wid })
    end
    return { restored = true, summary = entry.summary, session_id = sid, window_id = wid }
  end
  if wid == RETRY then
    lib.push(entry)
    return { restored = false, message = "Rex didn't answer, so nothing was reopened. Try again." }
  end
  -- The kind, not the summary: the summary has the command line, and Rex's
  -- log is something undo_clear can't empty.
  rex.log("rex-undo: couldn't reopen a closed " .. tostring(entry.kind) .. ": " .. tostring(wid))
  return { restored = false, message = "Couldn't reopen " .. name }
end

function M.history()
  local stack, out = lib.read_stack(), {}
  if #stack == 0 then return "Nothing to reopen" end
  for i = #stack, 1, -1 do
    local e = stack[i]
    out[#out + 1] = os.date("%Y-%m-%d %H:%M:%S", e.closed_at or 0) .. "  " .. (e.summary or e.kind)
  end
  return out
end

function M.clear()
  local n = lib.clear()
  if n == 0 then return "Nothing to clear" end
  return "Cleared " .. n .. (n == 1 and " closed item" or " closed items")
end

function M.start_watcher(opts)
  local script = opts.dir .. "/../bin/rex-undo-watch"
  local h, err = rex.exec.start({ "/bin/sh", script }, {
    detach = true,
    env = { REX_UNDO_DIR = opts.dir, REX_UNDO_REX = opts.rex or "rex" },
    stdout = false,
    stderr = false,
  })
  if not h then rex.log("rex-undo: couldn't start the watcher: " .. tostring(err)) end
end

function M.setup(opts)
  opts = opts or {}
  assert(opts.dir, "rex-undo: setup needs dir")
  lib = dofile(opts.dir .. "/lib.lua")

  -- How many closes to keep. A bad value keeps the default rather than
  -- failing the whole config.
  local n = tonumber(opts.history)
  if opts.history ~= nil and not (n and n >= 1 and n == math.floor(n)) then
    rex.log("rex-undo: history must be a whole number, 1 or more; keeping " .. lib.max_entries)
    n = nil
  end
  if n then
    lib.ensure_dirs()
    lib.write_raw(lib.settings_path, rex.json.encode({ history = n }))
    lib.max_entries = n
  else
    os.remove(lib.settings_path)
  end

  rex.action{
    name = "undo_close",
    title = "Reopen Closed Pane",
    description = "Reopen the pane, tab, or session closed most recently, and resume Claude in it.",
    category = "Undo",
    keywords = "undo reopen restore closed tab pane session claude resume",
    run = function(ctx) return M.undo(ctx) end,
  }
  rex.action{
    name = "undo_history",
    title = "Show Closed Panes",
    description = "List what Reopen Closed Pane can bring back, newest first.",
    category = "Undo",
    run = function() return M.history() end,
  }
  rex.action{
    name = "undo_clear",
    title = "Clear Closed Panes",
    description = "Forget every closed pane, tab, and session, with the command lines saved for them.",
    category = "Undo",
    keywords = "undo clear reset forget history closed",
    run = function() return M.clear() end,
  }

  if opts.key ~= false then rex.bind(opts.key or "cmd+shift+t", "undo_close") end
  if opts.watcher ~= false then M.start_watcher(opts) end
  return M
end

return M
