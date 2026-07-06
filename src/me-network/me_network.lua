-- me_network.lua
-- CC:Tweaked: AE2 storage capacity and power monitor.
-- Requires: Advanced Peripherals ME Bridge connected to ME network, Advanced Monitor.
--
-- Usage:
--   me_network           show both storage and power (combined view)
--   me_network storage   show only storage (optimised for a tall monitor)
--   me_network power     show only power   (optimised for a tall monitor)
--
-- Display refreshes every REFRESH seconds. Read-only — no touch needed.
-- Place the ME Bridge touching an AE2 cable on one face and this computer
-- (or a wired modem cable) on another face.

local REFRESH = 5   -- seconds between polls

local args = { ... }
local MODE = args[1] or "all"   -- "all" | "storage" | "power"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  return ok and res or nil
end

local function fmtNum(n)
  if not n then return "N/A" end
  n = math.floor(n)
  if n >= 1e12 then return ("%.2fT"):format(n / 1e12) end
  if n >= 1e9  then return ("%.2fB"):format(n / 1e9)  end
  if n >= 1e6  then return ("%.2fM"):format(n / 1e6)  end
  if n >= 1e3  then return ("%.1fK"):format(n / 1e3)  end
  return tostring(n)
end

local function pctStr(used, total)
  if not total or total == 0 then return "N/A" end
  return math.floor(used / total * 100) .. "%"
end

local function pctFill(used, total, barW)
  if not total or total == 0 then return 0 end
  return math.max(0, math.min(barW, math.floor(used / total * barW)))
end

-- ── peripheral setup ─────────────────────────────────────────────────────────

local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
if not bridge then
  error("No ME Bridge found. Attach an Advanced Peripherals ME Bridge.")
end

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach an Advanced Monitor.")
end

mon.setTextScale(0.5)

-- ── drawing helpers ───────────────────────────────────────────────────────────

local lastPollTime = 0

-- Full-width bar on its own row.
local function bigBar(row, used, total, fillColor)
  local w = select(1, mon.getSize())
  local barW   = w - 2
  local filled = pctFill(used or 0, total, barW)
  mon.setCursorPos(2, row)
  mon.setBackgroundColor(fillColor)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", barW - filled))
  mon.setBackgroundColor(colors.black)
end

-- Inline label + bar + pct (for the combined "all" view).
local function inlineBar(row, label, used, total, barW, fillColor)
  local w = select(1, mon.getSize())
  local filled = pctFill(used or 0, total, barW)
  local ps     = pctStr(used or 0, total)
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, row)
  mon.write(label)
  mon.setCursorPos(#label + 2, row)
  mon.setBackgroundColor(fillColor)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", barW - filled))
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.write(" " .. ps)
end

-- ── section renderers ─────────────────────────────────────────────────────────

local function drawStorageTall(data, row)
  local w, h = mon.getSize()

  local function sep()
    if row > h then return row end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write(string.rep("-", w))
    return row + 1
  end

  -- ITEMS
  if row <= h then
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(1, row); mon.write("ITEMS")
    row = row + 1
  end
  if data.itemTotal then
    if row <= h then bigBar(row, data.itemUsed, data.itemTotal, colors.green); row = row + 1 end
    if row <= h then
      local sub = "  " .. fmtNum(data.itemUsed) .. " / " .. fmtNum(data.itemTotal)
                .. "   " .. pctStr(data.itemUsed or 0, data.itemTotal)
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
    end
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Item storage unavailable"); row = row + 1
    end
  end

  row = sep()

  -- FLUIDS
  if row <= h then
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(1, row); mon.write("FLUIDS")
    row = row + 1
  end
  if data.fluidTotal then
    if row <= h then bigBar(row, data.fluidUsed, data.fluidTotal, colors.blue); row = row + 1 end
    if row <= h then
      local sub = "  " .. fmtNum(data.fluidUsed) .. " / " .. fmtNum(data.fluidTotal) .. " mB"
                .. "   " .. pctStr(data.fluidUsed or 0, data.fluidTotal)
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
    end
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Fluid storage unavailable"); row = row + 1
    end
  end

  return row
end

local function drawPowerTall(data, row)
  local w, h = mon.getSize()

  local function sep()
    if row > h then return row end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write(string.rep("-", w))
    return row + 1
  end

  -- STORED
  if row <= h then
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(1, row); mon.write("STORED")
    row = row + 1
  end
  if data.energyMax then
    if row <= h then bigBar(row, data.energyStored, data.energyMax, colors.yellow); row = row + 1 end
    if row <= h then
      local sub = "  " .. fmtNum(data.energyStored) .. " / " .. fmtNum(data.energyMax) .. " AE"
                .. "   " .. pctStr(data.energyStored or 0, data.energyMax)
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
    end
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Energy data unavailable"); row = row + 1
    end
  end

  row = sep()

  -- USAGE
  if data.energyUsage then
    if row <= h then
      mon.setTextColor(colors.cyan)
      mon.setCursorPos(1, row); mon.write("USAGE")
      row = row + 1
    end
    if row <= h then
      local usageStr = "  " .. fmtNum(data.energyUsage) .. " AE/t"
      mon.setTextColor(colors.white)
      mon.setCursorPos(1, row); mon.write(usageStr); row = row + 1
    end
  end

  return row
end

-- ── full draw ─────────────────────────────────────────────────────────────────

local function draw(data)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local row  = 1
  local BAR_W = math.max(8, math.floor(w * 0.38))

  local function sep()
    if row > h then return end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1
  end

  -- Title
  local title = MODE == "storage" and "ME STORAGE"
             or MODE == "power"   and "ME POWER"
             or "ME NETWORK"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, row)
  mon.write(title)
  row = row + 1
  sep()

  if MODE == "storage" then
    row = drawStorageTall(data, row)

  elseif MODE == "power" then
    row = drawPowerTall(data, row)

  else
    -- Combined: compact inline bars for both sections
    mon.setTextColor(colors.cyan); mon.setCursorPos(1, row); mon.write("STORAGE"); row = row + 1

    if data.itemTotal then
      inlineBar(row, "Items  ", data.itemUsed, data.itemTotal, BAR_W, colors.green); row = row + 1
      if row <= h then
        local sub = "  " .. fmtNum(data.itemUsed) .. " / " .. fmtNum(data.itemTotal)
        mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
      end
    else
      if row <= h then mon.setTextColor(colors.red); mon.setCursorPos(2, row); mon.write("Item storage unavailable"); row = row + 1 end
    end

    if data.fluidTotal then
      inlineBar(row, "Fluids ", data.fluidUsed, data.fluidTotal, BAR_W, colors.blue); row = row + 1
      if row <= h then
        local sub = "  " .. fmtNum(data.fluidUsed) .. " / " .. fmtNum(data.fluidTotal) .. " mB"
        mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
      end
    else
      if row <= h then mon.setTextColor(colors.red); mon.setCursorPos(2, row); mon.write("Fluid storage unavailable"); row = row + 1 end
    end

    sep()
    mon.setTextColor(colors.cyan); mon.setCursorPos(1, row); mon.write("POWER"); row = row + 1

    if data.energyMax then
      inlineBar(row, "Stored ", data.energyStored, data.energyMax, BAR_W, colors.yellow); row = row + 1
      if row <= h then
        local sub = "  " .. fmtNum(data.energyStored) .. " / " .. fmtNum(data.energyMax) .. " AE"
        mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(sub:sub(1, w)); row = row + 1
      end
    else
      if row <= h then mon.setTextColor(colors.red); mon.setCursorPos(2, row); mon.write("Energy data unavailable"); row = row + 1 end
    end

    if data.energyUsage and row <= h then
      local label = "Usage  "
      local value = fmtNum(data.energyUsage) .. " AE/t"
      local gap   = math.max(1, w - #label - #value)
      mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(label)
      mon.setTextColor(colors.white); mon.setCursorPos(1 + #label + gap, row); mon.write(value)
      row = row + 1
    end
  end

  -- Footer
  local ago = math.floor((os.epoch("utc") - lastPollTime) / 1000)
  local ft  = "Updated " .. ago .. "s ago"
  if h >= row then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(math.max(1, math.floor((w - #ft) / 2) + 1), h)
    mon.write(ft)
  end
end

-- ── main loop ─────────────────────────────────────────────────────────────────

print(("me-network [%s] running. Press Ctrl+T to stop."):format(MODE))
print("Bridge:  " .. peripheral.getName(bridge))
print("Monitor: " .. peripheral.getName(mon))

while true do
  local data = {
    itemUsed     = safeCall(bridge.getUsedItemStorage),
    itemTotal    = safeCall(bridge.getTotalItemStorage),
    fluidUsed    = safeCall(bridge.getUsedFluidStorage),
    fluidTotal   = safeCall(bridge.getTotalFluidStorage),
    energyStored = safeCall(bridge.getEnergyStorage),
    energyMax    = safeCall(bridge.getMaxEnergyStorage),
    energyUsage  = safeCall(bridge.getEnergyUsage),
  }
  lastPollTime = os.epoch("utc")
  draw(data)
  sleep(REFRESH)
end
