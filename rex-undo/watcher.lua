-- rex-undo watcher. Run with: rex do watcher.lua --all
--
-- Close events carry only an ID, so this keeps a snapshot of every session's
-- layout and of what each terminal is running. When something closes, it
-- compares the snapshot with the session as it is now and records what went
-- away on the undo stack.

local DIR = os.getenv("REX_UNDO_DIR")
  or debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
  or "."
local lib = dofile(DIR .. "/lib.lua")
local agents = dofile(DIR .. "/agents.lua")

local TERMINAL = "com.superlogical.terminal"
local SHELLS = {
  zsh = true, bash = true, fish = true, sh = true, dash = true, ksh = true,
  tcsh = true, csh = true, nu = true, xonsh = true, elvish = true, pwsh = true,
  login = true,
}
local INTERPRETERS = {
  node = true, bun = true, deno = true, python = true, python3 = true, ruby = true,
}
-- An agent that ended this many seconds before its pane closed is treated as
-- still running, in case closing the pane hung it up first.
local RECENT = 3
local SETTLE = 0.4

local views = {}    -- session ID -> last session.view
local blocks = {}   -- block ID -> what we know about the terminal
local closing = {}  -- session ID -> { view, destroyed, timer }

local function each_block(view, fn)
  for _, w in ipairs(view.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, b in ipairs(l.blocks or {}) do fn(b, w, l) end
    end
  end
end

-- pwd is a file:// URL after OSC 7, and a plain path otherwise.
local function url_path(url)
  if type(url) ~= "string" or url == "" then return nil end
  if url:sub(1, 7) ~= "file://" then return url end
  local p = url:match("^file://[^/]*(/.*)$")
  if not p then return nil end
  return (p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function base(s)
  return ((s or ""):gsub("^%-", ""):match("[^/]*$"))
end

-- A program's name without a script extension, so node's codex.js is codex.
local function stem(s)
  return (base(s):lower():gsub("%.[cm]?js$", ""):gsub("%.py$", ""))
end

local function shquote(s)
  if s:match("^[%w%._/%-=:@,+]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- An installed agent's script is a launcher with no extension or sits in a
-- package folder. `python3 claude.py` or `node ./bin/claude.js` is a script of
-- your own that shares an agent's name.
local function installed(path)
  return not base(path):find(".", 1, true) or path:find("/node_modules/", 1, true) ~= nil
    or path:find("/site-packages/", 1, true) ~= nil
end

-- The agent the program is. Its name alone isn't enough for a script of your
-- own, or for an agent marked `confirm` because another tool has its name
-- (fx the JSON viewer): those also need the program to have reported itself
-- to Rex as that agent, or a session ID found for it. `lenient` takes the name
-- alone, to look up that session ID.
local function find_agent(p, lenient)
  if not p then return nil end
  local names = { stem(p.name), stem(p.argv0), stem(p.invoked_path) }
  local scripts = {}
  if p.script then scripts[#scripts + 1] = p.script end
  -- An interpreter's first argument, as in `node /path/to/gemini.js`.
  local first, second = (p.args or ""):match("^(%S+)%s+(%S+)")
  if first and INTERPRETERS[stem(first)] then scripts[#scripts + 1] = second end
  local proven = lenient or p.session_id ~= nil
  for _, a in ipairs(agents) do
    for _, n in ipairs(a.apps or {}) do
      if p.app and p.app:lower() == n then return a end
    end
    for _, n in ipairs(a.names or {}) do
      for _, k in ipairs(names) do
        if k == n and (proven or not a.confirm) then return a end
      end
      for _, s in ipairs(scripts) do
        if stem(s) == n and (proven or (not a.confirm and installed(s))) then return a end
      end
    end
  end
end

local function is_shell(p)
  if p == nil then return true end
  -- `sh deploy.sh` runs a script, not an interactive shell.
  if p.script then return false end
  return (SHELLS[base(p.name)] or SHELLS[base(p.argv0)]) and true or false
end

local function slim(p)
  if type(p) ~= "table" then return nil end
  return {
    pid = p.pid, name = p.name, argv0 = p.argv0, path = p.path,
    invoked_path = p.invoked_path, script = p.script, cwd = p.cwd,
  }
end

local function set_foreground(info, fg)
  fg = slim(fg)
  if not fg then return end
  if info.fg and info.fg.pid == fg.pid then
    -- Keep what enrich found for this process.
    for k, v in pairs(fg) do info.fg[k] = v end
    return
  end
  info.prev_fg, info.fg_at, info.fg = info.fg, os.time(), fg
end

-- The hook's record, if the Claude that wrote it is the one running now. A
-- record from an earlier Claude in the pane would resume the wrong conversation.
local function claude_record(block_id, pid)
  local rec = lib.read_json(lib.claude_dir .. "/" .. block_id:gsub("^block:", "") .. ".json")
  if not (type(rec) == "table" and type(rec.session_id) == "string"
      and rec.session_id:match("^[%x%-]+$") and tonumber(rec.rex_pid)) then
    return nil
  end
  local writer = tonumber(rec.rex_pid)
  if writer ~= pid then
    -- The foreground process may be a wrapper that leads Claude's process group.
    local r = rex.exec({ "ps", "-o", "pgid=", "-p", tostring(writer) }, { timeout = 3 })
    if not (r and r.ok and tonumber(r.stdout:match("%d+")) == pid) then return nil end
  end
  return rec
end

-- Linux keeps each process's argv in /proc. macOS has no /proc, so there the
-- helper in bin asks the kernel.
local PROCFS = lib.exists("/proc/self/cmdline")

-- A process's argv, NUL between the words, or "" if it can't be read.
local function argv_bytes(pid)
  if not PROCFS then
    local r = rex.exec({ "perl", DIR .. "/../bin/rex-undo-argv", tostring(pid) }, { timeout = 3 })
    return (r and r.ok and r.stdout) or ""
  end
  local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  -- /proc ends every word with a NUL, the last one too.
  if s:sub(-1) == "\0" then s = s:sub(1, -2) end
  return s
end

-- The command line, quoted again so it reruns with the same words.
local function command_line(pid)
  local bytes = argv_bytes(pid)
  if bytes ~= "" then
    local raw, s, i = {}, bytes .. "\0", 1
    while i <= #s do
      local j = s:find("\0", i, true)
      raw[#raw + 1] = s:sub(i, j - 1)
      i = j + 1
    end
    -- A program that renames itself (npm, puma) writes its title over argv:
    -- `npm run dev` comes back as one word, then empty ones or the environment.
    -- The title is what was typed, so rerun that.
    local renamed = raw[1]:find("%s") ~= nil
    if not renamed and #raw > 1 then
      renamed = true
      for k = 2, #raw do if raw[k] ~= "" then renamed = false end end
    end
    if renamed then
      -- npm's title keeps only positional words and drops the `--` before them,
      -- so its first word starting with "-" came after a `--`. Put it back.
      if raw[1]:match("^npm ") then return (raw[1]:gsub(" %-", " -- -", 1)) end
      return raw[1]
    end
    local words = {}
    for k, w in ipairs(raw) do
      local q = shquote(w)
      -- A first word with "=" would read as a variable assignment.
      if k == 1 and q == w and w:find("=", 1, true) then q = "'" .. w .. "'" end
      words[k] = q
    end
    return table.concat(words, " ")
  end
  -- Loses quoting, but better than nothing if argv can't be read.
  local r = rex.exec({ "ps", "-o", "args=", "-p", tostring(pid) }, { timeout = 3 })
  if r and r.ok then return (r.stdout:gsub("%s+$", "")) end
end

-- The session file an agent keeps open names its session. The foreground
-- process may be a wrapper, such as node, so look at its whole process group.
local function open_session_id(pid, patterns)
  local r = rex.exec({ "lsof", "-Fn", "-b", "-w", "-n", "-P", "-g", tostring(pid), "-p", tostring(pid) },
    { timeout = 3 })
  if not (r and r.stdout) then return nil end
  for line in r.stdout:gmatch("[^\n]+") do
    if line:sub(1, 1) == "n" then
      for _, pat in ipairs(patterns) do
        local id = line:sub(2):match(pat)
        if id then return id end
      end
    end
  end
end

local function query_session_id(argv, cwd)
  local home = os.getenv("HOME") or ""
  local cmd = {}
  for i, arg in ipairs(argv) do
    cmd[i] = arg:gsub("{home}", function() return home end)
      :gsub("{cwd}", function() return (cwd:gsub("'", "''")) end)
  end
  local r = rex.exec(cmd, { timeout = 3 })
  local id = r and r.ok and r.stdout:match("^%s*(%S+)")
  if id and id:match("^[%w_%-]+$") then return id end
end

-- Fill in the command line, the agent, and its session for the foreground
-- program. Rex reports only argv0, so the full command line comes from the kernel.
local function enrich(sid, bid, info)
  local fg = info.fg
  if not fg or is_shell(fg) then return end
  if not fg.args then fg.args = command_line(fg.pid) end
  -- npm titles itself plain `npm` while it starts, and `npm run dev` only once
  -- it has read its config. Caught in between, look again until it has.
  local tries = 0
  local function recheck()
    if fg.args ~= "npm" or tries >= 5 or info.fg ~= fg then return end
    tries = tries + 1
    rex.after(1, function()
      if info.fg ~= fg then return end
      fg.args = command_line(fg.pid) or fg.args
      recheck()
    end)
  end
  recheck()
  local st = rex.block.call(TERMINAL, "program_status", { session_id = sid, block_id = bid })
  for _, rec in ipairs((st and st.records) or {}) do
    if rec.owner and rec.owner.pid == fg.pid and rec.effective_app then fg.app = rec.effective_app end
  end

  -- Lenient: the session ID found here is what proves a doubtful name.
  local a = find_agent(fg, true)
  if not a then return end
  if a.hook then
    local rec = claude_record(bid, fg.pid)
    if rec then
      fg.session_id, fg.transcript = rec.session_id, rec.transcript_path
      fg.cwd = rec.cwd or fg.cwd
      return
    end
  end
  if a.files then fg.session_id = open_session_id(fg.pid, a.files) or fg.session_id end
  if a.query and fg.cwd then fg.session_id = query_session_id(a.query, fg.cwd) or fg.session_id end
end

local function info_for(b)
  local info = blocks[b.block_id]
  if not info then
    info = {}
    blocks[b.block_id] = info
  end
  info.flavor, info.creator, info.label = b.flavor, b.creator_name, b.label
  return info
end

local function probe(sid, b)
  local info = info_for(b)
  if b.creator_name ~= TERMINAL then return end
  local p = rex.block.call(TERMINAL, "process", { session_id = sid, block_id = b.block_id })
  if p then set_foreground(info, p.foreground or p.child) end
  local d = rex.block.call(TERMINAL, "pwd", { session_id = sid, block_id = b.block_id })
  info.cwd = (d and url_path(d.pwd)) or info.cwd or (info.fg and info.fg.cwd)
  enrich(sid, b.block_id, info)
end

local on_close

local function refresh(sid, reprobe)
  if not sid or closing[sid] then return end
  local view = rex.session.view{ session_id = sid }
  if not view then return end
  -- A block missing from the new view closed before its close event reached
  -- us, or its event comes later. Keep the snapshot that still has it, and
  -- settle as for a close; finalize tells a close from a move.
  local old = views[sid]
  if old then
    local now, gone = {}, false
    each_block(view, function(b) now[b.block_id] = true end)
    each_block(old, function(b) if not now[b.block_id] then gone = true end end)
    if gone then return on_close(sid) end
  end
  views[sid] = view
  each_block(view, function(b)
    if reprobe or not blocks[b.block_id] then probe(sid, b) else info_for(b) end
  end)
end

local function scan(reprobe)
  local list = rex.call("session.list")
  for _, s in ipairs((list and list.sessions) or {}) do refresh(s.session_id, reprobe) end
end

-- nil when the list call fails, which says nothing either way.
local function session_listed(sid)
  local list = rex.call("session.list")
  if not (list and list.sessions) then return nil end
  for _, s in ipairs(list.sessions) do
    if s.session_id == sid then return true end
  end
  return false
end

-- Turning a snapshot into creation requests -----------------------------------

-- An agent's command line names a session already, as in `codex resume ID`.
local function names_session(args)
  if not args then return false end
  for _, w in ipairs({ "%sresume", "%-%-resume", "%-%-session", "%-%-continue", "%s%-[rcsS]%s", "%s%-[rcsS]$" }) do
    if args:find(w) then return true end
  end
  return false
end

-- The command that brings the program back, and a short description of it.
local function command_for(fg)
  local a = find_agent(fg)
  if not a then
    local cmd = fg.args or base(fg.name)
    return cmd, cmd
  end
  local name = a.names[1]
  -- Claude saves nothing before the first message, so there's nothing to resume.
  if a.hook and fg.transcript and not lib.exists(fg.transcript) then
    return name, name .. " (new)"
  end
  if fg.session_id and a.resume then
    local id = fg.session_id
    return (a.resume:gsub("{id}", function() return shquote(id) end)), name .. " " .. id:sub(1, 12)
  end
  if names_session(fg.args) then return fg.args, fg.args end
  if a.continue then return a.continue, name .. " (latest here)" end
  return fg.args or name, fg.args or name
end

-- Returns the block request and a short description of what it will run.
local function block_spec(b)
  local spec = { flavor = b.flavor }
  if b.creator_name ~= TERMINAL then
    if b.label then spec.label = b.label end
    return spec, b.flavor
  end

  local info = blocks[b.block_id] or {}
  local opts = {}
  spec.options = opts
  opts.cwd = info.cwd

  local fg = info.fg
  if is_shell(fg) and info.prev_fg and find_agent(info.prev_fg)
      and os.time() - (info.fg_at or 0) <= RECENT then
    fg = info.prev_fg
  end
  if is_shell(fg) then return spec, "shell" end

  local cmd, desc = command_for(fg)
  -- An agent's sessions belong to the folder it started in.
  if find_agent(fg) and fg.cwd then opts.cwd = fg.cwd end
  -- Typed into a shell, so the pane stays open after the program exits.
  opts.initial_input = cmd .. "\n"
  return spec, desc
end

local function layout_spec(node, by_id, ids, what)
  if node.split then
    local s = node.split
    return { split = {
      direction = s.direction,
      ratio = s.ratio,
      before = layout_spec(s.before, by_id, ids, what),
      after = layout_spec(s.after, by_id, ids, what),
    } }
  end
  local b = by_id[node.block_id] or { block_id = node.block_id, flavor = "com.superlogical.terminal.shell", creator_name = TERMINAL }
  local spec, desc = block_spec(b)
  ids[#ids + 1] = node.block_id
  what[#what + 1] = desc
  return { block = spec }
end

local function default_label(label, kind)
  return label == nil or label:match("^" .. kind .. " %x+$") ~= nil
end

local function window_spec(w, what)
  local layers = {}
  for _, l in ipairs(w.layers or {}) do
    if l.layout then
      local by_id = {}
      for _, b in ipairs(l.blocks or {}) do by_id[b.block_id] = b end
      local ids = {}
      layers[#layers + 1] = {
        kind = l.kind,
        bounds = l.bounds,
        layout = layout_spec(l.layout, by_id, ids, what),
        block_ids = ids,
      }
    end
  end
  return {
    window_id = w.window_id,
    label = (not default_label(w.label, "Window")) and w.label or nil,
    layers = layers,
  }
end

local function find_parent(node, id)
  local s = node and node.split
  if not s then return nil end
  if s.before.block_id == id then return s, "before", s.after end
  if s.after.block_id == id then return s, "after", s.before end
  local a, b, c = find_parent(s.before, id)
  if a then return a, b, c end
  return find_parent(s.after, id)
end

local function blocks_in(node, out)
  if node.split then
    blocks_in(node.split.before, out)
    blocks_in(node.split.after, out)
  else
    out[#out + 1] = node.block_id
  end
  return out
end

-- The window without the blocks still in its session, or nil if that's all of
-- them: a tab whose only pane moved to another tab or was detached didn't close.
local function without(w, alive)
  local function prune(node)
    if not node.split then return (not alive[node.block_id]) and node or nil end
    local s = node.split
    local b, a = prune(s.before), prune(s.after)
    if b and a then
      return { split = { split_id = s.split_id, direction = s.direction, ratio = s.ratio, before = b, after = a } }
    end
    return b or a
  end
  local layers = {}
  for _, l in ipairs(w.layers or {}) do
    local layout = l.layout and prune(l.layout)
    if layout then
      layers[#layers + 1] = { kind = l.kind, bounds = l.bounds, layout = layout, blocks = l.blocks }
    end
  end
  if #layers == 0 then return nil end
  return { window_id = w.window_id, label = w.label, layers = layers }
end

-- Where a closed pane sat: the split it shared, and something beside it to
-- split again.
local function placement(layer, id, alive)
  local p = { floating = layer.kind == "floating" and layer.bounds or nil }
  local s, side, sibling = find_parent(layer.layout, id)
  if not s then
    p.root = true
    return p
  end
  p.direction, p.side, p.ratio = s.direction, side, s.ratio
  p.anchors = {}
  if sibling.split then p.anchors[#p.anchors + 1] = sibling.split.split_id end
  for _, bid in ipairs(blocks_in(sibling, {})) do
    if alive[bid] then p.anchors[#p.anchors + 1] = bid end
  end
  return p
end

local function summary(kind, label, what)
  local seen, parts = {}, {}
  for _, d in ipairs(what) do
    if not seen[d] then
      seen[d] = true
      parts[#parts + 1] = d
    end
  end
  return string.format("%s in %s: %s", kind, label or "?", table.concat(parts, ", "))
end

-- Recording closes -------------------------------------------------------------

local function record(entry)
  entry.closed_at = os.time()
  lib.push(entry)
  print(os.date("%H:%M:%S") .. " recorded " .. entry.summary)
end

local finalize -- below; settle's retry calls it

local function settle(sid)
  local c = closing[sid]
  closing[sid] = nil
  if not c then return end
  local old = c.view
  local fresh = (not c.destroyed) and rex.session.view{ session_id = sid } or nil

  -- A failed view read (a timeout, say) isn't a closed session. Recording one
  -- would make undo open a copy of a session that's still there.
  if not fresh and not c.destroyed and session_listed(sid) ~= false then
    c.tries = (c.tries or 0) + 1
    if c.tries < 5 then
      closing[sid] = c
      c.timer = rex.after(SETTLE, function() finalize(sid) end)
    end
    return
  end

  if not fresh then
    local what, windows, active = {}, {}, nil
    for i, w in ipairs(old.windows or {}) do
      windows[#windows + 1] = window_spec(w, what)
      if w.window_id == old.active_window_id then active = i end
    end
    if #windows > 0 then
      record{
        kind = "session",
        session_id = sid,
        session_label = old.label,
        windows = windows,
        active_index = active,
        summary = summary("session", old.label, what),
      }
    end
    each_block(old, function(b) blocks[b.block_id] = nil end)
    views[sid] = nil
    return
  end

  local alive_w, alive_b = {}, {}
  for _, w in ipairs(fresh.windows or {}) do alive_w[w.window_id] = true end
  each_block(fresh, function(b) alive_b[b.block_id] = true end)
  -- A detached block is in no window, but it's still running.
  local all = rex.session.list_blocks{ session_id = sid }
  for _, b in ipairs((all and all.blocks) or {}) do alive_b[b.block_id] = true end

  local windows = old.windows or {}
  for i, w in ipairs(windows) do
    local gone = not alive_w[w.window_id] and without(w, alive_b)
    if gone then
      local next_id
      for j = i + 1, #windows do
        if alive_w[windows[j].window_id] then
          next_id = windows[j].window_id
          break
        end
      end
      local what = {}
      record{
        kind = "window",
        session_id = sid,
        session_label = old.label,
        before_window_id = next_id,
        window = window_spec(gone, what),
        summary = summary("tab", old.label, what),
      }
    elseif alive_w[w.window_id] then
      local panes, what = {}, {}
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          if not alive_b[b.block_id] then
            local spec, desc = block_spec(b)
            what[#what + 1] = desc
            panes[#panes + 1] = {
              block_id = b.block_id,
              block = spec,
              placement = placement(l, b.block_id, alive_b),
            }
          end
        end
      end
      if #panes > 0 then
        record{
          kind = "panes",
          session_id = sid,
          session_label = old.label,
          window_id = w.window_id,
          window_label = (not default_label(w.label, "Window")) and w.label or nil,
          panes = panes,
          summary = summary(#panes == 1 and "pane" or "panes", old.label, what),
        }
      end
    end
  end

  each_block(old, function(b)
    if not alive_b[b.block_id] then blocks[b.block_id] = nil end
  end)
  -- What was just recorded is the new baseline, even if the read below fails;
  -- otherwise the next close would record these again.
  views[sid] = fresh
  refresh(sid)
end

-- A close isn't in the history until it settles (SETTLE seconds, longer if
-- the watcher is busy), so while one is pending a marker with the time tells
-- undo to wait for it rather than reopen the close before.
local function mark_settling()
  if next(closing) then
    pcall(lib.write_raw, lib.settling_path, tostring(os.time()))
  else
    os.remove(lib.settling_path)
  end
end

function finalize(sid)
  local ok, err = pcall(settle, sid)
  mark_settling()
  if not ok then error(err, 0) end
end

function on_close(sid, destroyed)
  if not sid then return end
  local c = closing[sid]
  if not c then
    if not views[sid] then return end
    c = { view = views[sid] }
    closing[sid] = c
  end
  if destroyed then c.destroyed = true end
  if c.timer then c.timer:cancel() end
  c.timer = rex.after(SETTLE, function() finalize(sid) end)
  mark_settling()
end

-- Events -------------------------------------------------------------------------

rex.on("session_view_changed", function(ctx) refresh(ctx.session_id) end)
rex.on("session_created", function(ctx, ev)
  refresh((ev.session and ev.session.session_id) or ctx.session_id)
end)

rex.on("terminal.process_changed", function(ctx, ev)
  local info = blocks[ctx.block_id]
  if info and ev.foreground then
    set_foreground(info, ev.foreground)
    enrich(ctx.session_id, ctx.block_id, info)
  end
end)

-- process_changed only reaches us for terminals a client is showing. Programs
-- such as Claude set the title or a status when they start, so look then too.
local function reprobe(ctx)
  local view = views[ctx.session_id]
  if not view or not blocks[ctx.block_id] then return end
  each_block(view, function(b)
    if b.block_id == ctx.block_id then probe(ctx.session_id, b) end
  end)
end
rex.on("terminal.title_changed", reprobe)
rex.on("terminal.program_status_changed", reprobe)

rex.on("terminal.pwd_changed", function(ctx, ev)
  local info = blocks[ctx.block_id]
  if info then info.cwd = url_path(ev.pwd) or info.cwd end
end)

rex.on("block_closed", function(ctx, ev) on_close(ev.session_id or ctx.session_id) end)
rex.on("window_closed", function(ctx, ev) on_close(ev.session_id or ctx.session_id) end)
rex.on("session_destroyed", function(ctx, ev)
  on_close(ev.session_id or ctx.session_id, true)
end)

-- API calls work once the script is attached, which is after this file runs.
rex.after(0, function()
  lib.ensure_dirs()
  os.remove(lib.settling_path) -- left by a copy that stopped mid-close
  rex.exec({ "find", lib.claude_dir, "-name", "*.json", "-mtime", "+14", "-delete" })
  scan(true)
  print(os.date("%H:%M:%S") .. " watching")
end)
-- A safety net for process changes an event didn't report. It probes the
-- cached views rather than reading new ones, so it can't replace the snapshot
-- a close is about to be compared against.
rex.every(5, function()
  for sid, view in pairs(views) do
    if not closing[sid] then
      each_block(view, function(b) probe(sid, b) end)
    end
  end
end)
