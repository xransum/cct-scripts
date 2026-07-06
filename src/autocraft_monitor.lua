-- pastebin get 58Ld1uFU autocraft_monitor
-- autocraft_monitor.lua
-- AE2 Live Auto-Crafting Monitor
-- Place: computer with ME Bridge attached to the face touching your dense cable
-- Monitor: attached directly to the computer (or via wired modem if remote)

local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
local mon = peripheral.find("monitor")

if not bridge then
  error("No ME Bridge found. Check peripheral.getNames() and confirm the bridge is attached to the correct face.")
end
if not mon then
  error("No monitor found. Confirm it is directly adjacent to the computer.")
end

mon.setTextScale(0.5)
local w, h = mon.getSize()

-- Colors (fall back gracefully if this is a basic, non-advanced monitor)
local hasColor = mon.isColor and mon.isColor()

local COL_BG = colors.black
local COL_IDLE = colors.lime
local COL_BUSY = colors.yellow
local COL_FAIL = colors.red
local COL_TEXT = colors.white
local COL_HEADER = colors.cyan
local COL_QUEUE = colors.orange

local function setColors(fg, bg)
  if hasColor then
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
  end
end

local function clear()
  setColors(COL_TEXT, COL_BG)
  mon.setBackgroundColor(COL_BG)
  mon.clear()
end

local function writeAt(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  setColors(fg or COL_TEXT, bg or COL_BG)
  mon.write(text)
end

-- Keep a small rolling history of completed/failed jobs
local history = {}
local MAX_HISTORY = 6

local function pushHistory(line)
  table.insert(history, 1, line)
  while #history > MAX_HISTORY do
    table.remove(history)
  end
end

-- Track previous CPU states so we can detect completions/failures for the log
local prevState = {}

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function getCPUs()
  -- Different ME Bridge versions expose slightly different method names.
  local list = safeCall(bridge.getCraftingCPUs) or safeCall(bridge.getCpus) or {}
  return list
end

local function formatItemName(item)
  if not item then return "idle" end
  if type(item) == "table" then
    return item.displayName or item.name or "unknown item"
  end
  return tostring(item)
end

local function drawDashboard()
  clear()
  writeAt(1, 1, "AE2 CRAFTING DASHBOARD", COL_HEADER, COL_BG)
  writeAt(1, 2, string.rep("-", w))

  local cpus = getCPUs()
  local row = 3
  local queuedCount = 0

  if #cpus == 0 then
    writeAt(1, row, "No crafting CPUs detected.", COL_FAIL, COL_BG)
  end

  for i, cpu in ipairs(cpus) do
    local busy = cpu.isBusy or cpu.busy or false
    local name = cpu.name or ("CPU " .. i)
    local storage = cpu.storage or cpu.size or 0
    local coProcessors = cpu.coProcessors or cpu.processors or 0

    local statusColor = busy and COL_BUSY or COL_IDLE
    local statusText = busy and "BUSY" or "IDLE"

    local itemLabel = "-"
    if busy then
      itemLabel = formatItemName(cpu.crafting or cpu.job or cpu.currentItem)
    end

    -- crude progress estimate: elapsed items produced vs storage capacity if available
    local progressText = ""
    if busy and cpu.progress then
      progressText = string.format(" (%d%%)", math.floor(cpu.progress * 100))
    end

    writeAt(1, row, string.format("[%s]", statusText), statusColor, COL_BG)
    writeAt(9, row, string.format("%s  %dk  %s%s", name, math.floor(storage / 1000), itemLabel, progressText), COL_TEXT, COL_BG)

    -- detect state changes for the history log
    local key = name
    local wasBusy = prevState[key]
    if wasBusy == true and busy == false then
      pushHistory(string.format("Finished on %s", name))
    end
    prevState[key] = busy

    if not busy then
      -- no-op, just idle
    else
      queuedCount = queuedCount -- placeholder, real queue data pulled below if API supports it
    end

    row = row + 1
  end

  row = row + 1
  writeAt(1, row, string.rep("-", w))
  row = row + 1
  writeAt(1, row, "RECENT ACTIVITY", COL_HEADER, COL_BG)
  row = row + 1
  for _, line in ipairs(history) do
    writeAt(1, row, line, COL_TEXT, COL_BG)
    row = row + 1
    if row > h then break end
  end
end

-- Main loop: redraw every 2 seconds. Adjust to taste, lower = more responsive but more lag on big networks.
while true do
  local ok, err = pcall(drawDashboard)
  if not ok then
    clear()
    writeAt(1, 1, "Error: " .. tostring(err), COL_FAIL, COL_BG)
  end
  sleep(2)
end