-- Alias: lets you type "reactor <cmd>" from the shell instead of "reactor_monitor <cmd>"
local args = { ... }
if #args > 0 then
  shell.run("reactor_monitor", table.unpack(args))
else
  shell.run("reactor_monitor")
end
