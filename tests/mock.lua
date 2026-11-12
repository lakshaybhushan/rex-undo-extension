-- A stand-in for the `rex` global, enough for lib.lua, undo.lua, and watcher.lua.
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function ser(v)
  if type(v) == "table" then
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  -- %q writes a newline as backslash-newline; JSON never puts one in a value.
  return type(v) == "string" and (string.format("%q", v):gsub("\\\n", "\\n")) or tostring(v)
end

local M = { handlers = {}, timers = {}, views = {}, sessions = {}, calls = {} }
rex = {
  json = {
    encode = ser,
    decode = function(s)
      if s == "[]" or s == "{}" then return {} end
      return assert(loadstring("return " .. s))()
    end,
  },
  exec = setmetatable({ start = function() return {} end }, { __call = function(_, argv)
    local cmd = {}
    for i, a in ipairs(argv) do cmd[i] = q(a) end
    local p = io.popen(table.concat(cmd, " ") .. " 2>/dev/null; echo \"__rc=$?\"")
    local out = p:read("*a"); p:close()
    local rc = tonumber(out:match("__rc=(%d+)%s*$"))
    return { ok = rc == 0, stdout = out:gsub("__rc=%d+%s*$", "") }
  end }),
  on = function(name, fn) M.handlers[name] = fn end,
  after = function(_, fn)
    local t = { fn = fn, cancel = function(self) self.cancelled = true end }
    M.timers[#M.timers + 1] = t
    return t
  end,
  every = function() end,
  log = function() end, action = function() end, bind = function() end,
  call = function(method, args)
    M.calls[#M.calls + 1] = method
    if method == "session.list" then
      if M.list_fail then return nil end
      local out = {}
      for sid in pairs(M.sessions) do out[#out + 1] = { session_id = sid } end
      return { sessions = out }
    end
    if M.on_call then return M.on_call(method, args) end
    return {}
  end,
  block = { call = function(...) return M.block_call and M.block_call(...) end },
  client = { queue = function() end },
  session = setmetatable({
    view = function(a)
      if M.view_error then error("boom") end
      return M.views[a.session_id]
    end,
  }, { __index = function(_, k) return function(a) return M.on_call and M.on_call("session." .. k, a) end end }),
}

-- Run timers until none are left (or n rounds), like the event loop would.
function M.run_timers()
  local ts = M.timers
  M.timers = {}
  for _, t in ipairs(ts) do if not t.cancelled then t.fn() end end
end
return M
