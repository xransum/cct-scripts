-- material_usage_monitor.lua
-- AE2 Material Usage Ticker + Auto Depletion Alarm + Top Movers
-- Place: computer with ME Bridge (direct or via wired modem), monitor attached.
-- Requires an ADVANCED monitor for touch buttons. A speaker peripheral is
-- optional but needed for the depletion alarm sound.
--
-- Watchlist lives in usage_watchlist.cfg, edit it with usage_config.lua.
-- Autoscan settings live in autoscan.cfg, also editable with usage_config.lua.
-- Tracked state persists to usage_state.cfg so counts and rates survive a
-- restart or power outage instead of starting blank.

local WATCHLIST_PATH = "usage_watchlist.cfg"
local AUTOSCAN_PATH = "autoscan.cfg"
local STATE_PATH = "usage_state.cfg"

local DEFAULT_WATCHLIST = {
  { name = "minecraft:iron_ingot",   label = "Iron Ingot",   threshold = 5,  priority = 1 },
  { name = "minecraft:copper_ingot", label = "Copper Ingot", threshold = 5,  priority = 2 },
  { name = "minecraft:redstone",     label = "Redstone",     threshold = 10, priority = 3 },
  { name = "minecraft:gold_ingot",   label = "Gold Ingot",   threshold = 3,  priority = 4 },
}

-- minQuantity: only items with at least this many in stock trip the
-- depletion alarm, so a stack of 12 nails does not trip anything.
-- depletionPercentPerMin: how fast a tracked item's stock has to shrink,
-- as a percent of its own current stock per minute, before it alarms.
-- scanInterval: seconds between full network scans, keep this generous.
-- topN: how many entries show on the top movers view.
local DEFAULT_AUTOSCAN = {
  enabled = true,
  minQuantity = 1000,
  depletionPercentPerMin = 15,
  scanInterval = 30,
  topN = 8,
}

local function saveTable(path, data)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(data))
  f.close()
end

local function loadTable(path, default)
  if not fs.exists(path) then
    saveTable(path, default)
    return default
  end
  local f = fs.open(path, "r")
  local contents = f.readAll()
  f.close()
  local ok, parsed = pcall(textutils.unserialize, contents)
  if ok and type(parsed) == "table" then
    return parsed
  end
  saveTable(path, default)
  return default
end

local function normalizeEntry(item)
  item.threshold = item.threshold or 1
  item.priority = item.priority or 99
  return item
end

local function loadWatchlist()
  local list = loadTable(WATCHLIST_PATH, DEFAULT_WATCHLIST)
  for _, item in ipairs(list) do
    normalizeEntry(item)
  end
  table.sort(list, function(a, b) return a.priority < b.priority end)
  return list
end

local function loadAutoscan()
  local cfg = loadTable(AUTOSCAN_PATH, DEFAULT_AUTOSCAN)
  cfg.minQuantity = cfg.minQuantity or DEFAULT_AUTOSCAN.minQuantity
  cfg.depletionPercentPerMin = cfg.depletionPercentPerMin or DEFAULT_AUTOSCAN.depletionPercentPerMin
  cfg.scanInterval = cfg.scanInterval or DEFAULT_AUTOSCAN.scanInterval
  cfg.topN = cfg.topN or DEFAULT_AUTOSCAN.topN
  return cfg
end

-- Persisted state: last known count and timestamp per item, for both the
-- watchlist ticker and the autoscan snapshot. Saved on a timer, not every
-- single poll, to keep disk writes cheap.
local function loadPersistedState()
  return loadTable(STATE_PATH, { watchlist = {}, snapshot = {} })
end

local function savePersistedState(watchlistState, snapshotState)
  saveTable(STATE_PATH, { watchlist = watchlistState, snapshot = snapshotState })
end

local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
local mon = peripheral.find("monitor")
local speaker = peripheral.find("speaker")

if not bridge then
  error("No ME Bridge found. Check peripheral.getNames and confirm the bridge is attached or wired in.")
end
if not mon then
  error("No monitor found. Confirm it is directly adjacent to the computer or wired via modem.")
end

mon.setTextScale(0.5)
local w, h = mon.getSize()

local hasColor = mon.isColor and mon.isColor()

local COL_BG = colors.black
local COL_TEXT = colors.white
local COL_HEADER = colors.cyan
local COL_UP = colors.lime
local COL_DOWN = colors.red
local COL_FLAT = colors.lightGray
local COL_BUTTON = colors.yellow
local COL_ALERT_BG = colors.red
local COL_ALERT_TEXT = colors.white

local function setColors(fg, bg)
  if hasColor then
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
  end
end

local function clear()
  mon.setBackgroundColor(COL_BG)
  mon.clear()
end

local function writeAt(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  setColors(fg or COL_TEXT, bg or COL_BG)
  mon.write(text)
end

local watchlist = loadWatchlist()
local autoscan = loadAutoscan()
local persisted = loadPersistedState()

local POLL_WINDOW = 10

-- rolling state per watchlist item, keyed by item name
local state = {}

local function buildState(list)
  local newState = {}
  for _, item in ipairs(list) do
    local carried = state[item.name]
    local restored = persisted.watchlist and persisted.watchlist[item.name]
    newState[item.name] = carried or {
      lastCount = restored and restored.lastCount or nil,
      lastTime = restored and restored.lastTime or nil,
      ratePerMin = 0,
      indicator = "flat",
    }
    newState[item.name].label = item.label
    newState[item.name].threshold = item.threshold
    newState[item.name].priority = item.priority
  end
  state = newState
end

buildState(watchlist)

-- bulk scan snapshot, keyed by item name, restored from disk on startup
local snapshot = {}
if persisted.snapshot then
  for name, entry in pairs(persisted.snapshot) do
    snapshot[name] = entry
  end
end

local topMovers = {}
local nextScanAt = 0  -- epoch seconds when the next auto-scan fires

local function safeCall(fn, ...)
  if not fn then return nil end
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function queryItem(name)
  local result = safeCall(bridge.getItem, { name = name })
  if result then
    return result.amount or result.count or 0
  end
  return 0
end

local function listAllItems()
  local result = safeCall(bridge.listItems) or safeCall(bridge.getItems) or safeCall(bridge.items)
  return result or {}
end

local function pollOne(item)
  local s = state[item.name]
  local count = queryItem(item.name)
  local now = os.epoch("utc") / 1000

  if s.lastCount ~= nil and s.lastTime ~= nil then
    local elapsed = now - s.lastTime
    if elapsed > 0 then
      local delta = count - s.lastCount
      s.ratePerMin = (delta / elapsed) * 60
    end
  end

  if s.ratePerMin > s.threshold then
    s.indicator = "up"
  elseif s.ratePerMin < -s.threshold then
    s.indicator = "down"
  else
    s.indicator = "flat"
  end

  s.lastCount = count
  s.lastTime = now
  s.currentCount = count
end

local function arrowFor(indicator)
  if indicator == "up" then
    return "UP", COL_UP
  elseif indicator == "down" then
    return "DOWN", COL_DOWN
  end
  return "--", COL_FLAT
end

-- button layout, bottom row, title bar stays at the top
local ADD_BTN_LABEL = "[+ add]"
local HELP_BTN_LABEL = "[? help]"
local ALL_BTN_LABEL = "[all]"
local ADD_BTN_X = 1
local ADD_BTN_Y = h
local ALL_BTN_X = #ADD_BTN_LABEL + 2
local ALL_BTN_Y = h
local HELP_BTN_X = w - #HELP_BTN_LABEL + 1
local HELP_BTN_Y = h

local view = "dashboard" -- dashboard | help | addinfo | allitems

local alertActive = false
local alertMessage = ""

local function drawButtons()
  writeAt(ADD_BTN_X, ADD_BTN_Y, ADD_BTN_LABEL, COL_BUTTON, COL_BG)
  writeAt(ALL_BTN_X, ALL_BTN_Y, ALL_BTN_LABEL, COL_BUTTON, COL_BG)
  writeAt(HELP_BTN_X, HELP_BTN_Y, HELP_BTN_LABEL, COL_BUTTON, COL_BG)
end

local function isInButton(x, y, btnX, btnY, label)
  return y == btnY and x >= btnX and x < btnX + #label
end

local function drawAlertBanner(row)
  if not alertActive then return row end
  writeAt(1, row, string.rep(" ", w), COL_ALERT_TEXT, COL_ALERT_BG)
  writeAt(1, row, " ALERT: " .. alertMessage .. " (tap to dismiss)", COL_ALERT_TEXT, COL_ALERT_BG)
  return row + 1
end

-- Writes a right-aligned next-scan countdown flush to the top-right corner
-- of row 1. All draw functions call this immediately after the header write.
local function drawCountdown()
  local label
  if not autoscan.enabled or nextScanAt == 0 then
    label = "  --"
  else
    local secsLeft = math.max(0, math.floor(nextScanAt - os.epoch("utc") / 1000))
    if secsLeft >= 1000 then
      label = "999+"
    else
      label = string.format("%3ds", secsLeft)
    end
  end
  writeAt(w - 3, 1, label, COL_FLAT, COL_BG)
end

local function drawDashboard()
  clear()
  writeAt(1, 1, "MATERIAL USAGE TICKER", COL_HEADER, COL_BG)
  drawCountdown()
  drawButtons()
  local row = 2
  row = drawAlertBanner(row)
  writeAt(1, row, string.rep("-", w))
  row = row + 1

  for _, item in ipairs(watchlist) do
    local s = state[item.name]
    local arrowText, arrowColor = arrowFor(s.indicator)
    local rateText = string.format("%.1f/min", s.ratePerMin or 0)
    local countText = s.currentCount and tostring(s.currentCount) or "?"

    writeAt(1, row, arrowText, arrowColor, COL_BG)
    writeAt(6, row, s.label, COL_TEXT, COL_BG)
    writeAt(24, row, countText, COL_TEXT, COL_BG)
    writeAt(32, row, rateText, arrowColor, COL_BG)

    row = row + 1
    if row > h - 1 then break end
  end
end

local function drawHelp()
  clear()
  writeAt(1, 1, "HELP", COL_HEADER, COL_BG)
  drawCountdown()
  drawButtons()
  local row = 2
  row = drawAlertBanner(row)
  writeAt(1, row, string.rep("-", w))
  row = row + 1

  local lines = {
    "UP/DOWN/-- show whether a",
    "watched item is trending",
    "past its own threshold.",
    "",
    "Priority sets display",
    "order, 1 shows first.",
    "",
    "The red banner is the",
    "auto depletion alarm. It",
    "watches your whole ME",
    "network for big stacks",
    "draining fast, no manual",
    "watchlist entry needed.",
    "",
    "Tap all for a top movers",
    "view across every item,",
    "built from the same scan",
    "the alarm already runs.",
    "",
    "Tap + to add a watchlist",
    "item from the computer.",
    "Tap help again for ticker.",
  }

  for _, line in ipairs(lines) do
    writeAt(1, row, line, COL_TEXT, COL_BG)
    row = row + 1
    if row > h - 1 then break end
  end
end

local function drawAddInfo()
  clear()
  writeAt(1, 1, "ADD ITEM", COL_HEADER, COL_BG)
  drawCountdown()
  drawButtons()
  local row = 2
  row = drawAlertBanner(row)
  writeAt(1, row, string.rep("-", w))
  row = row + 1

  local lines = {
    "Monitors cannot accept",
    "typed input directly.",
    "",
    "Go to the computer and",
    "run:",
    "",
    "  usage_config add",
    "",
    "It will walk you through",
    "item id, label, threshold,",
    "and priority, and reject",
    "bad input with a reason.",
    "",
    "Tap + again to go back.",
  }

  for _, line in ipairs(lines) do
    writeAt(1, row, line, COL_TEXT, COL_BG)
    row = row + 1
    if row > h - 1 then break end
  end
end

local function drawAllItems()
  clear()
  writeAt(1, 1, "TOP MOVERS (ALL ITEMS)", COL_HEADER, COL_BG)
  drawCountdown()
  drawButtons()
  local row = 2
  row = drawAlertBanner(row)
  writeAt(1, row, string.rep("-", w))
  row = row + 1

  if #topMovers == 0 then
    writeAt(1, row, "Waiting on first network scan...", COL_TEXT, COL_BG)
    return
  end

  for _, mover in ipairs(topMovers) do
    local arrowColor = COL_FLAT
    if mover.rate > 0 then
      arrowColor = COL_UP
    elseif mover.rate < 0 then
      arrowColor = COL_DOWN
    end
    local rateText = string.format("%.1f/min", mover.rate)

    writeAt(1, row, mover.label, COL_TEXT, COL_BG)
    writeAt(28, row, rateText, arrowColor, COL_BG)

    row = row + 1
    if row > h - 1 then break end
  end
end

local function render()
  if view == "help" then
    drawHelp()
  elseif view == "addinfo" then
    drawAddInfo()
  elseif view == "allitems" then
    drawAllItems()
  else
    drawDashboard()
  end
end

local function isBannerTap(x, y)
  return alertActive and y == 2
end

-- Manual watchlist polling. Skips redraw while other screens are open so
-- it does not yank the view back to the ticker mid read. Saves state to
-- disk once per full pass through the watchlist, not every poll.
local function pollLoop()
  local idx = 1
  while true do
    if #watchlist == 0 then
      if view == "dashboard" then
        clear()
        writeAt(1, 1, "Watchlist is empty.", COL_DOWN, COL_BG)
        writeAt(1, 2, "Run usage_config add", COL_TEXT, COL_BG)
        drawButtons()
      end
      sleep(5)
    else
      local pollInterval = POLL_WINDOW / #watchlist
      local item = watchlist[idx]

      pcall(pollOne, item)
      if view == "dashboard" then
        local ok2, err2 = pcall(drawDashboard)
        if not ok2 then
          clear()
          writeAt(1, 1, "Render error: " .. tostring(err2), COL_DOWN, COL_BG)
        end
      end

      idx = idx + 1
      if idx > #watchlist then
        idx = 1
        watchlist = loadWatchlist()
        buildState(watchlist)

        -- persist watchlist state after every full pass
        local watchlistSnapshot = {}
        for name, s in pairs(state) do
          watchlistSnapshot[name] = { lastCount = s.lastCount, lastTime = s.lastTime }
        end
        savePersistedState(watchlistSnapshot, snapshot)
      end

      sleep(pollInterval)
    end
  end
end

-- Auto-scan loop: infrequent full network scan, tracks every item's rate
-- for the top movers view, and flags any big stack draining faster than
-- depletionPercentPerMin of its own current stock. One bulk call covers
-- both features, no extra network cost for tracking everything at once.
local function autoScanLoop()
  while true do
    autoscan = loadAutoscan()
    if not autoscan.enabled then
      sleep(5)
    else
      local items = listAllItems()
      local now = os.epoch("utc") / 1000
      local movers = {}

      for _, it in ipairs(items) do
        local amt = it.amount or it.count or 0
        local nm = it.name
        if nm then
          local prev = snapshot[nm]
          local rate = 0

          if prev and prev.lastTime then
            local elapsed = now - prev.lastTime
            if elapsed > 0 then
              local delta = amt - prev.lastCount
              rate = (delta / elapsed) * 60

              if amt >= autoscan.minQuantity and delta < 0 and prev.lastCount > 0 then
                local percentPerMin = (math.abs(delta) / prev.lastCount) * (60 / elapsed) * 100
                if percentPerMin > autoscan.depletionPercentPerMin then
                  local label = it.displayName or nm
                  alertActive = true
                  alertMessage = label .. " -" .. string.format("%.0f", percentPerMin) .. "%/min"
                  if speaker then
                    safeCall(speaker.playSound, "minecraft:block.note_block.pling")
                  end
                  render()
                end
              end
            end
          end

          snapshot[nm] = { lastCount = amt, lastTime = now }

          if rate ~= 0 then
            table.insert(movers, { label = it.displayName or nm, rate = rate })
          end
        end
      end

      table.sort(movers, function(a, b) return math.abs(a.rate) > math.abs(b.rate) end)
      topMovers = {}
      for i = 1, math.min(autoscan.topN, #movers) do
        topMovers[i] = movers[i]
      end

      if view == "allitems" then
        pcall(drawAllItems)
      end

      -- persist snapshot state after every full scan
      local watchlistSnapshot = {}
      for name, s in pairs(state) do
        watchlistSnapshot[name] = { lastCount = s.lastCount, lastTime = s.lastTime }
      end
      savePersistedState(watchlistSnapshot, snapshot)

      nextScanAt = os.epoch("utc") / 1000 + autoscan.scanInterval
      sleep(autoscan.scanInterval)
    end
  end
end

-- Touch loop: help, add, all-items buttons, and banner dismiss.
local function touchLoop()
  while true do
    local event, side, x, y = os.pullEvent("monitor_touch")
    if isBannerTap(x, y) then
      alertActive = false
      alertMessage = ""
      render()
    elseif isInButton(x, y, HELP_BTN_X, HELP_BTN_Y, HELP_BTN_LABEL) then
      view = (view == "help") and "dashboard" or "help"
      render()
    elseif isInButton(x, y, ADD_BTN_X, ADD_BTN_Y, ADD_BTN_LABEL) then
      view = (view == "addinfo") and "dashboard" or "addinfo"
      render()
    elseif isInButton(x, y, ALL_BTN_X, ALL_BTN_Y, ALL_BTN_LABEL) then
      view = (view == "allitems") and "dashboard" or "allitems"
      render()
    end
  end
end

render()

-- Ticks once per real second to keep the scan countdown current without
-- triggering a full screen redraw.
local function countdownLoop()
  while true do
    sleep(1)
    pcall(drawCountdown)
  end
end

parallel.waitForAny(pollLoop, autoScanLoop, touchLoop, countdownLoop)
