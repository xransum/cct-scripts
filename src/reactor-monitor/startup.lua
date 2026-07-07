-- Pass all arguments through so CLI commands work:
--   reactor setup / status / scram / on / off / rods / mode
local args = { ... }
if #args > 0 then
  shell.run("reactor_monitor", table.unpack(args))
else
  shell.run("reactor_monitor")
end
