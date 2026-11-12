-- Pushes N entries; run two copies at once to check the stack lock.
package.path = arg[1] .. "/tests/?.lua;" .. package.path
require("mock")
local lib = dofile(arg[1] .. "/rex-undo/lib.lua")
lib.max_entries = 10000
for i = 1, tonumber(arg[3]) do lib.push({ kind = "panes", summary = arg[2] .. i }) end
