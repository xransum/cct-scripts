-- me_network.lua
-- CC:Tweaked: AE2 storage capacity and power monitor.
-- Requires: Advanced Peripherals ME Bridge connected to ME network, Advanced Monitor.
--
-- Display refreshes every REFRESH seconds. No touch interaction needed — read-only.
-- Place the ME Bridge touching an AE2 cable on one face and this computer (or a
-- wired modem cable) on another face.

local REFRESH = 5   -- seconds between polls

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

local function pct(used, total)
  if not total or total == 0 then return 0 end
  return math.floor(used / total * 100)
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

-- ── drawing ──────────────────────────────────────────────────────────────────

-- Draws a filled-background progress bar.
-- fillColor: color of the filled portion
-- Returns the next available column after the bar + pct label.
local function drawBar(row, startCol, barWidth, used, total, fillColor)
  local filled = total and total > 0 and math.floor(used / total * barWidth) or 0
  local pctStr = total and total > 0 and (pct(used, total) .. "%") or "N/A"

  mon.setCursorPos(startCol, row)
  mon.setBackgroundColor(fillColor)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", barWidth - filled))
  mon.setBackgroundColor(colors.black)

  mon.setTextColor(colors.white)
  mon.write(" " .. pctStr)
end

local lastPollTime = 0

local function draw(data)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local row = 1
  local BAR_W = math.max(8, math.floor(w * 0.38))

  local function sep()
    if row > h then return end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row)
    mon.write(string.rep("-", w))
    row = row + 1
  end

  local function sectionHeader(label)
    if row > h then return end
    mon.setTextColor(colors.aqua)
    mon.setCursorPos(1, row)
    mon.write(label)
    row = row + 1
  end

  local function rowLV(label, value, lc, vc)
    if row > h then return end
    local gap = math.max(1, w - #label - #value)
    mon.setTextColor(lc or colors.gray)
    mon.setCursorPos(1, row)
    mon.write(label)
    mon.setTextColor(vc or colors.white)
    mon.setCursorPos(1 + #label + gap, row)
    mon.write(value)
    row = row + 1
  end

  local function barRow(label, used, total, fillColor, unit)
    if row > h then return end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row)
    mon.write(label)
    drawBar(row, #label + 2, BAR_W, used or 0, total, fillColor)
    row = row + 1

    -- sub-row: used / total
    if row <= h then
      local sub = "  " .. fmtNum(used) .. " / " .. fmtNum(total) .. (unit and ("  " .. unit) or "")
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, row)
      mon.write(sub:sub(1, w))
      row = row + 1
    end
  end

  -- Title
  local title = "ME NETWORK"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, row)
  mon.write(title)
  row = row + 1

  sep()

  -- ── STORAGE ──────────────────────────────────────────────────────────────
  sectionHeader("STORAGE")

  if data.itemTotal then
    barRow("Items  ", data.itemUsed, data.itemTotal, colors.green, nil)
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Item storage unavailable"); row = row + 1
    end
  end

  if data.fluidTotal then
    barRow("Fluids ", data.fluidUsed, data.fluidTotal, colors.blue, "mB")
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Fluid storage unavailable"); row = row + 1
    end
  end

  sep()

  -- ── POWER ─────────────────────────────────────────────────────────────────
  sectionHeader("POWER")

  if data.energyMax then
    barRow("Stored ", data.energyStored, data.energyMax, colors.yellow, "AE")
  else
    if row <= h then
      mon.setTextColor(colors.red); mon.setCursorPos(2, row)
      mon.write("Energy data unavailable"); row = row + 1
    end
  end

  if data.energyUsage and row <= h then
    rowLV("Usage  ", fmtNum(data.energyUsage) .. " AE/t", colors.gray, colors.white)
  end

  -- Footer: updated timestamp
  if h > row then
    local ago = math.floor((os.epoch("utc") - lastPollTime) / 1000)
    local ft  = "Updated " .. ago .. "s ago"
    mon.setTextColor(colors.gray)
    mon.setCursorPos(math.max(1, math.floor((w - #ft) / 2) + 1), h)
    mon.write(ft)
  end
end

-- ── main loop ─────────────────────────────────────────────────────────────────

print("me-network running. Press Ctrl+T to stop.")
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
