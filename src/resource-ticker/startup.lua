-- startup.lua
-- Launches material_usage_monitor in a background multishell tab on
-- computer boot, leaving the foreground terminal free for usage_config
-- and other commands. Requires an Advanced Computer (multishell).
shell.run("bg material_usage_monitor")