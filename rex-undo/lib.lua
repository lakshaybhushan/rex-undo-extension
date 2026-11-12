-- Shared by watcher.lua (run with `rex do`) and undo.lua (loaded from init.lua).

local M = {}

local home = os.getenv("HOME") or ""
M.state_dir = (os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/rex-undo"
M.claude_dir = M.state_dir .. "/claude"
M.stack_path = M.state_dir .. "/stack.jsonl"
M.old_stack_path = M.state_dir .. "/stack.json" -- one JSON array, before 2026-11
M.remap_path = M.state_dir .. "/remap.json"
M.max_entries = 50 -- unless settings.json, written by undo.lua's setup, says otherwise
M.settings_path = M.state_dir .. "/settings.json"
M.remap_max = 100

function M.ensure_dirs()
  rex.exec({ "mkdir", "-p", M.claude_dir })
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

function M.read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if s == nil or s:match("^%s*$") then return nil end
  local ok, value = pcall(rex.json.decode, s)
  if ok then return value end
  return nil
end

-- Write through a temporary file so a reader never sees half a file.
function M.write_raw(path, text)
  -- A table's address differs between processes; math.random isn't seeded.
  local tmp = string.format("%s.%d.%s.tmp", path, os.time(), tostring({}):gsub("%W", ""))
  local f = assert(io.open(tmp, "w"))
  local wrote, err = f:write(text)
  local closed, cerr = f:close()
  -- A short write (a full disk) must not replace the file with a cut-off one.
  if not (wrote and closed) then
    os.remove(tmp)
    error("rex-undo: couldn't write " .. path .. ": " .. tostring(err or cerr), 0)
  end
  assert(os.rename(tmp, path))
end

-- The history is one entry per line, oldest first. A push or pop then
-- touches only its own line: decoding all 50 entries of a big history takes
-- ~10ms in Rex, a line well under one. JSON never puts a newline inside a value.
local function read_text()
  local f = io.open(M.stack_path, "r")
  if f then
    local s = f:read("*a") or ""
    f:close()
    if s ~= "" and s:sub(-1) ~= "\n" then s = s .. "\n" end
    return s
  end
  local old = M.read_json(M.old_stack_path)
  local lines = {}
  for i, e in ipairs(type(old) == "table" and old or {}) do lines[i] = rex.json.encode(e) .. "\n" end
  return table.concat(lines)
end

local function write_text(text)
  M.write_raw(M.stack_path, text)
  os.remove(M.old_stack_path)
end

-- Where each line ends.
local function line_ends(text)
  local ends, i = {}, 1
  while true do
    local j = text:find("\n", i, true)
    if not j then return ends end
    ends[#ends + 1] = j
    i = j + 1
  end
end

-- Every entry, oldest first. A line that doesn't decode is skipped.
function M.read_stack()
  local text, stack, from = read_text(), {}, 1
  for _, e in ipairs(line_ends(text)) do
    local ok, v = pcall(rex.json.decode, text:sub(from, e - 1))
    if ok and type(v) == "table" then stack[#stack + 1] = v end
    from = e + 1
  end
  return stack
end

-- The undo action (in the server) and the watcher (its own process) both
-- read, change, and write the stack, so each change holds a lock, or one
-- process's write would drop the other's entry. mkdir is atomic.
M.lock_path = M.state_dir .. "/stack.lock"
function M.locked(fn)
  local deadline, made = os.time() + 10, false
  while true do
    local r = rex.exec({ "mkdir", M.lock_path })
    if r and r.ok then break end
    -- The folder may not exist yet (first use, or after --purge). Checking
    -- only here saves a process start on every change.
    if not made then
      made = true
      M.ensure_dirs()
      r = rex.exec({ "mkdir", M.lock_path })
      if r and r.ok then break end
    end
    if os.time() > deadline then error("rex-undo: " .. M.lock_path .. " is busy", 0) end
    -- A holder takes milliseconds, so a lock older than 5s was left by one
    -- that died. Remove it and try again; never run without the lock, and
    -- never remove a lock that's in use.
    -- shortcut: a holder stalled for over 5s (the Mac slept mid-write) loses
    -- its lock, and two waiters on one stale lock can both get in. Both need a
    -- rare stall or crash first; a kernel lock (lockf) would close them.
    rex.exec({ "find", M.lock_path, "-maxdepth", "0", "-mtime", "+5s", "-exec", "rmdir", M.lock_path, ";" })
    rex.exec({ "sleep", "0.02" })
  end
  local ok, value = pcall(fn)
  rex.exec({ "rmdir", M.lock_path })
  if not ok then error(value, 0) end
  return value
end

function M.push(entry)
  M.locked(function()
    local text = read_text() .. rex.json.encode(entry) .. "\n"
    local ends = line_ends(text)
    -- Keep the newest entries. Read each time: the watcher outlives a config
    -- reload that changes the limit.
    local s = M.read_json(M.settings_path)
    local max = (type(s) == "table" and tonumber(s.history)) or M.max_entries
    if #ends > max then text = text:sub(ends[#ends - max] + 1) end
    write_text(text)
  end)
end

-- Takes the newest entry off. A line that doesn't decode is dropped and the
-- one before it is tried.
function M.pop()
  return M.locked(function()
    local text = read_text()
    local ends = line_ends(text)
    for i = #ends, 1, -1 do
      local from = (ends[i - 1] or 0) + 1
      local ok, v = pcall(rex.json.decode, text:sub(from, ends[i] - 1))
      if ok and type(v) == "table" then
        write_text(text:sub(1, from - 1))
        return v
      end
    end
    if #ends > 0 then write_text("") end
  end)
end

-- Empties the history and the ID map that only its entries use. Returns how
-- many entries there were.
function M.clear()
  return M.locked(function()
    local n = #line_ends(read_text())
    write_text("")
    M.write_raw(M.remap_path, "{}")
    return n
  end)
end

-- IDs of things undo recreated, old ID to new ID, so a later undo of a pane
-- that lived in a restored tab or session lands back in it.
function M.read_remap()
  local m = M.read_json(M.remap_path)
  if type(m) ~= "table" then return {} end
  return m
end

-- Merge into the file under the lock, so two undos keep each other's IDs.
-- Past remap_max IDs, keep only those the stack still names, pointing
-- straight at the newest one, so the file doesn't grow forever. That reads
-- the whole history, so it isn't done on every press.
function M.write_remap(map)
  M.locked(function()
    local merged, n = M.read_remap(), 0
    for k, v in pairs(map) do merged[k] = v end
    for _ in pairs(merged) do n = n + 1 end
    if n > M.remap_max then
      local wanted = {}
      local function walk(v)
        if type(v) == "table" then
          for _, x in pairs(v) do walk(x) end
        elseif type(v) == "string" then
          wanted[v] = true
        end
      end
      walk(M.read_stack())
      local out = {}
      for k in pairs(merged) do
        if wanted[k] then out[k] = M.resolve(merged, k) end
      end
      merged = out
    end
    M.write_raw(M.remap_path, next(merged) == nil and "{}" or rex.json.encode(merged))
  end)
end

function M.resolve(map, id)
  local seen = 0
  while id and map[id] and seen < 64 do
    id = map[id]
    seen = seen + 1
  end
  return id
end

return M
