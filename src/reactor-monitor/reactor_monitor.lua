-- reactor_monitor.lua
-- CC:Tweaked: Extreme Reactors 2 monitor & control system.
-- Supports 1–N Advanced Monitors with adaptive single-monitor tab mode.
-- Panels: Dashboard (stats+control), Rods (per-rod insertion), SCRAM (emergency).
-- Auto-rod mode adjusts all rods to hit a target FE/t setpoint.
-- Speaker support for sound feedback (optional).
--
-- Usage:
--   reactor_monitor           start normally
--   reactor_monitor setup     re-run interactive configurator
--   reactor_monitor status    dump stats to terminal
--   reactor_monitor scram     emergency shutdown from terminal
--   reactor_monitor on|off    turn reactor on/off from terminal
--   reactor_monitor rods <N>  set all rods to N% (0-100)
--   reactor_monitor mode passive|active

-- ── constants ─────────────────────────────────────────────────────────────────

local CFG_FILE        = "reactor_monitor.cfg"
local DRAW_INTERVAL   = 2    -- seconds between redraws
local AUTO_INTERVAL   = 5    -- seconds between auto-rod adjustments
local ROD_STEP        = 5    -- % per tap or auto-step (fine)
local ROD_STEP_FAST   = 5    -- % per auto-step (coarse, large error)
local AUTO_TARGET_DEF = 10000
local SCRAM_ROD_LEVEL = 100
local MAX_ROD_AUTO    = 95   -- auto never exceeds this; 100 reserved for SCRAM

-- Sound events (speaker.playSoundEffect)
local SND_SCRAM     = "actuallyadditions:duh_duh_duh_duuuh"
local SND_ALARM     = "mekanism:tile.machine.industrial_alarm"
local SND_ON        = "create:confirm_2"
local SND_OFF       = "create:deny"
local SND_ROD       = "create:scroll_value"
local SND_CONFIRM   = "create:confirm"

-- Panel identifiers
local PANEL_DASHBOARD = "dashboard"
local PANEL_RODS      = "rods"
local PANEL_SCRAM     = "scram"
local PANELS          = { PANEL_DASHBOARD, PANEL_RODS, PANEL_SCRAM }

-- ── peripherals ───────────────────────────────────────────────────────────────

local reactor = peripheral.find("extremereactor-reactorComputerPort")
               or peripheral.find("BigReactors-Reactor")
if not reactor then
  error("No Extreme Reactors computer port found. Attach or wire one to this computer.")
end

local speaker = peripheral.find("speaker")

local function playSound(snd, vol, pitch)
  if speaker then
    pcall(speaker.playSoundEffect, snd, vol or 1.0, pitch or 1.0)
  end
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function saveTable(path, data)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(data))
  f.close()
end

local function loadTable(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  local raw = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, raw)
  return (ok and type(t) == "table") and t or default
end

local function fmtNum(n)
  -- thousands separator
  local s = tostring(math.floor(n))
  local result = ""
  local cnt = 0
  for i = #s, 1, -1 do
    if cnt > 0 and cnt % 3 == 0 then result = "," .. result end
    result = s:sub(i,i) .. result
    cnt = cnt + 1
  end
  return result
end

local function fmtFE(n)
  if n >= 1e9 then return string.format("%.1fGFE", n/1e9)
  elseif n >= 1e6 then return string.format("%.1fMFE", n/1e6)
  elseif n >= 1e3 then return string.format("%.1fkFE", n/1e3)
  else return fmtNum(n).."FE" end
end

local function fmtFEt(n)
  if n >= 1e6 then return string.format("%.1fMFE/t", n/1e6)
  elseif n >= 1e3 then return string.format("%.1fkFE/t", n/1e3)
  else return fmtNum(n).."FE/t" end
end

local function bar(filled, total, width)
  local n = total > 0 and math.floor(filled / total * width) or 0
  n = math.max(0, math.min(width, n))
  return string.rep("\x8f", n) .. string.rep("-", width - n)
end

local function pct(a, b)
  if type(a) ~= "number" or type(b) ~= "number" or b == 0 then return 0 end
  return math.floor(a / b * 100)
end

local function fmtStep(n)
  if n >= 1000000 then return string.format("%dM", n/1000000)
  elseif n >= 1000 then return string.format("%dk", n/1000)
  else return tostring(n) end
end

local function tempColor(t)
  if t < 500  then return colors.lime
  elseif t < 1000 then return colors.yellow
  elseif t < 1500 then return colors.orange
  else return colors.red end
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Collect all monitors, return sorted list of {name, mon} pairs
local function getMonitors()
  local list = {}
  local names = peripheral.getNames()
  table.sort(names)
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      list[#list+1] = { name = name, mon = peripheral.wrap(name) }
    end
  end
  return list
end

-- ── config ────────────────────────────────────────────────────────────────────

local cfg = loadTable(CFG_FILE, {})

local function saveCfg()
  saveTable(CFG_FILE, cfg)
end

-- ── reactor state (polled every DRAW_INTERVAL) ────────────────────────────────

local state = {}

local function pollReactor()
  -- Helper: call a reactor method, return number or fallback
  local function rnum(fn, fallback)
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then return v end
    return fallback or 0
  end
  local function rbool(fn, fallback)
    local ok, v = pcall(fn)
    if ok and type(v) == "boolean" then return v end
    return fallback or false
  end

  local ok, err = pcall(function()
    state.active         = rbool(reactor.getActive, false)
    state.fuelTemp       = rnum(reactor.getFuelTemperature)
    state.casingTemp     = rnum(reactor.getCasingTemperature)
    state.fuelAmt        = rnum(reactor.getFuelAmount)
    state.fuelMax        = rnum(reactor.getFuelAmountMax, 1)
    state.wasteAmt       = rnum(reactor.getWasteAmount)
    state.energyStored   = rnum(reactor.getEnergyStored)
    state.energyCap      = rnum(reactor.getEnergyCapacity, 1)
    state.reactivity     = rnum(reactor.getFuelReactivity)
    state.fuelConsumed   = rnum(reactor.getFuelConsumedLastTick)
    state.rodCount       = rnum(reactor.getNumberOfControlRods, 0)
    state.activeCooled   = rbool(reactor.isActivelyCooled, false)
    if state.activeCooled then
      state.energyLastTick = rnum(reactor.getHotFluidProducedLastTick)
    else
      state.energyLastTick = rnum(reactor.getEnergyProducedLastTick)
    end
    -- Rod levels
    state.rodLevels = state.rodLevels or {}
    local count = math.floor(state.rodCount)
    for i = 0, count - 1 do
      local ok2, v = pcall(reactor.getControlRodLevel, i)
      state.rodLevels[i] = (ok2 and type(v) == "number") and v or 0
    end
  end)
  if not ok then
    state.error = tostring(err)
  else
    state.error = nil
  end
end

-- ── auto-rod controller ───────────────────────────────────────────────────────

local function autoAdjustRods()
  if not cfg.autoMode or not cfg.autoTarget then return end
  if not state.active or state.error then return end

  local current = state.energyLastTick or 0
  local target  = cfg.autoTarget
  local err     = current - target  -- positive = over-producing, negative = under-producing

  -- Scale step size to error magnitude for smoother convergence.
  -- Higher rod insertion = more rods in = less flux = less output.
  -- Over target  → insert rods (+insertion) to reduce output.
  -- Under target → withdraw rods (-insertion) to increase output.
  local absErr = math.abs(err)
  local delta  = 0
  if absErr > 5000 then
    delta = err > 0 and 10 or -10   -- large error: big step
  elseif absErr > 2000 then
    delta = err > 0 and  5 or  -5   -- medium error: normal step
  elseif absErr > 500 then
    delta = err > 0 and  2 or  -2   -- small error: fine step
  end
  -- Dead-band: within ±500 FE/t of target → leave rods alone

  if delta ~= 0 then
    local current_level = state.rodLevels and state.rodLevels[0] or 50
    local new_level = clamp(current_level + delta, 0, MAX_ROD_AUTO)
    if new_level ~= current_level then
      pcall(reactor.setAllControlRodLevels, new_level)
    end
  end
end

-- ── monitor assignment helpers ────────────────────────────────────────────────

-- Returns the peripheral object for a panel, or nil if not assigned/missing
local function panelMon(panel)
  local name = cfg[panel]
  if not name then return nil end
  if not peripheral.isPresent(name) then return nil end
  local t = peripheral.getType(name)
  if t ~= "monitor" then return nil end
  return peripheral.wrap(name)
end

-- Determine if we're in single-monitor tab mode
-- Returns the single monitor object if tab mode, nil otherwise
local function singleTabMon()
  local assigned = {}
  for _, p in ipairs(PANELS) do
    local name = cfg[p]
    if name and peripheral.isPresent(name) then
      assigned[name] = true
    end
  end
  local count = 0
  local mon = nil
  for name, _ in pairs(assigned) do
    count = count + 1
    mon = peripheral.wrap(name)
  end
  -- Also check if no assignments exist but exactly one monitor is present
  if count == 0 then
    local mons = getMonitors()
    if #mons == 1 then return mons[1].mon end
    return nil
  end
  if count == 1 then return mon end
  return nil
end

-- ── SCRAM state ───────────────────────────────────────────────────────────────

local scramPending    = false   -- waiting for confirmation tap
local scramMonitor    = nil     -- which monitor is showing the confirm overlay
local alarmTimer      = nil     -- repeating alarm while confirm pending

local function executeScram()
  pcall(reactor.setActive, false)
  pcall(reactor.setAllControlRodLevels, SCRAM_ROD_LEVEL)
  playSound(SND_SCRAM, 1.0, 1.0)
  scramPending = false
  alarmTimer   = nil
end

local function cancelScram()
  scramPending = false
  alarmTimer   = nil
end

-- ── tab state (single-monitor mode) ──────────────────────────────────────────

local tabIndex = 1   -- 1=dashboard, 2=rods, 3=scram
local TAB_LABELS = { "Dashboard", "Rods", "SCRAM" }

-- Auto-target step size cycles: 500 → 5k → 50k → 1M → back to 500
local AUTO_STEPS    = { 500, 5000, 50000, 1000000 }
local autoStepIndex = 1

-- ── rod panel scroll state ────────────────────────────────────────────────────

local rodScrollOffset = 0

-- ── draw: shared primitives ───────────────────────────────────────────────────

local function clearMon(mon)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
end

local function drawSep(mon, w, r)
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, r)
  mon.write(string.rep("-", w))
end

local function writeAt(mon, x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  if fg  then mon.setTextColor(fg) end
  if bg  then mon.setBackgroundColor(bg) end
  mon.write(text)
  mon.setBackgroundColor(colors.black)
end

local function centered(mon, w, y, text, fg)
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(mon, x, y, text:sub(1,w), fg or colors.white)
end

-- ── touch hitbox registry (per-monitor, rebuilt each draw) ────────────────────
-- hitboxes[monName] = list of {x1,y1,x2,y2,action}

local hitboxes = {}

local function clearHitboxes(monName)
  hitboxes[monName] = {}
end

local function addHit(monName, x1, y1, x2, y2, action)
  local t = hitboxes[monName] or {}
  t[#t+1] = {x1=x1, y1=y1, x2=x2, y2=y2, action=action}
  hitboxes[monName] = t
end

local function hitTest(monName, x, y)
  local t = hitboxes[monName] or {}
  for _, h in ipairs(t) do
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then
      return h.action
    end
  end
end

-- ── draw: tab strip (single-monitor mode) ─────────────────────────────────────

local function drawTabStrip(mon, monName, w)
  mon.setBackgroundColor(colors.black)
  mon.setCursorPos(1, 1)
  mon.write(string.rep(" ", w))
  local col = 1
  for i, label in ipairs(TAB_LABELS) do
    local tag = "["..label.."]"
    if col + #tag - 1 > w then break end
    if i == tabIndex then
      mon.setBackgroundColor(colors.gray)
      mon.setTextColor(colors.yellow)
    else
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.gray)
    end
    writeAt(mon, col, 1, tag)
    addHit(monName, col, 1, col + #tag - 1, 1, "tab_"..i)
    col = col + #tag + 1
  end
  mon.setBackgroundColor(colors.black)
  drawSep(mon, w, 2)
end

-- ── draw: dashboard panel ─────────────────────────────────────────────────────

local function drawDashboard(mon, monName, startRow)
  local w, h = mon.getSize()
  local row = startRow

  local function at(r) return row <= r and r <= h end
  local function sep(r) if at(r) then drawSep(mon, w, r) end end

  -- Title row
  if at(row) then
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(1, row)
    mon.write("REACTOR MONITOR")
    -- ON / OFF button
    local onLabel  = "[ON]"
    local offLabel = "[OFF]"
    local btnX = w - #offLabel - #onLabel - 1
    mon.setTextColor(state.active and colors.lime or colors.gray)
    writeAt(mon, btnX, row, onLabel)
    addHit(monName, btnX, row, btnX + #onLabel - 1, row, "reactor_on")
    mon.setTextColor(state.active and colors.gray or colors.red)
    writeAt(mon, btnX + #onLabel + 1, row, offLabel)
    addHit(monName, btnX + #onLabel + 1, row, w, row, "reactor_off")
  end
  row = row + 1
  sep(row); row = row + 1

  -- Status + mode
  if at(row) then
    local statusStr = state.active and "ONLINE" or "OFFLINE"
    local statusCol = state.active and colors.lime or colors.red
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write("Status:")
    mon.setTextColor(statusCol)
    mon.setCursorPos(9, row); mon.write(statusStr)
    local coolingMode = cfg.coolingMode or "passive"
    local modeStr = "Mode: "..(coolingMode == "active" and "Active" or "Passive")
    mon.setTextColor(colors.cyan)
    local mx = w - #modeStr + 1
    mon.setCursorPos(mx, row); mon.write(modeStr)
  end
  row = row + 1
  sep(row); row = row + 1

  -- Fuel bar
  if at(row) then
    local fp     = pct(state.fuelAmt or 0, state.fuelMax or 1)
    local amtStr = string.format("%d/%d mB", state.fuelAmt or 0, state.fuelMax or 0)
    local prefix = "Fuel: "
    -- bar fills the gap between prefix and right-aligned amtStr
    -- layout: "Fuel: [####----] 642276/700000 mB"
    -- col 1..#prefix, then "[", bar, "]", " ", amtStr right-aligned
    local bw  = math.max(2, w - #prefix - 2 - 1 - #amtStr)  -- 2 = "[" + "]", 1 = space
    local col = fp > 30 and colors.lime or fp > 10 and colors.yellow or colors.red
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(prefix)
    mon.setTextColor(col)
    mon.write("[" .. bar(state.fuelAmt or 0, state.fuelMax or 1, bw) .. "]")
    mon.setTextColor(colors.white)
    mon.write(" " .. amtStr)
  end
  row = row + 1

  -- Waste bar
  if at(row) then
    local wp     = pct(state.wasteAmt or 0, state.fuelMax or 1)
    local amtStr = string.format("%d mB (%d%%)", state.wasteAmt or 0, wp)
    local prefix = "Waste:"
    local bw  = math.max(2, w - #prefix - 2 - 1 - #amtStr)
    local col = wp < 20 and colors.lime or wp < 50 and colors.yellow or colors.red
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(prefix)
    mon.setTextColor(col)
    mon.write("[" .. bar(state.wasteAmt or 0, state.fuelMax or 1, bw) .. "]")
    mon.setTextColor(colors.white)
    mon.write(" " .. amtStr)
  end
  row = row + 1
  sep(row); row = row + 1

  -- Temperatures + reactivity
  if at(row) then
    local ft = math.floor(state.fuelTemp or 0)
    local ct = math.floor(state.casingTemp or 0)
    local ftStr = string.format("Fuel: %dC", ft)
    local ctStr = string.format("Case: %dC", ct)
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(ftStr:sub(1,6))
    mon.setTextColor(tempColor(ft)); mon.write(tostring(ft).."C")
    local half = math.floor(w/2)
    mon.setTextColor(colors.gray); mon.setCursorPos(half+1, row); mon.write("Case: ")
    mon.setTextColor(tempColor(ct)); mon.write(tostring(ct).."C")
  end
  row = row + 1

  if at(row) then
    local rxStr = string.format("%.1f%%", state.reactivity or 0)
    local fcStr = string.format("%.3f mB/t", state.fuelConsumed or 0)
    local half  = math.floor(w / 2)
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write("React:")
    mon.setTextColor(colors.cyan); mon.write(" " .. rxStr)
    mon.setTextColor(colors.gray); mon.setCursorPos(half + 1, row); mon.write("F/t:")
    mon.setTextColor(colors.white)
    -- allow up to end of line
    mon.write(" " .. fcStr:sub(1, w - half - 5))
  end
  row = row + 1
  sep(row); row = row + 1

  -- Energy output + stored
  if at(row) then
    local isActive = cfg.coolingMode == "active"
    local outLabel = isActive and "Output:" or "Output:"
    local outVal   = isActive
      and string.format("%.0f mB/t hot", state.energyLastTick or 0)
      or  fmtFEt(state.energyLastTick or 0)
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(outLabel.." ")
    mon.setTextColor(colors.lime); mon.write(outVal:sub(1, w-9))
  end
  row = row + 1

  if at(row) then
    local ep      = pct(state.energyStored or 0, state.energyCap or 1)
    local amtStr  = fmtFE(state.energyStored or 0) .. "/" .. fmtFE(state.energyCap or 0)
    local prefix  = "Stored:"
    local bw      = math.max(2, w - #prefix - 2 - 1 - #amtStr)
    local col     = ep > 30 and colors.cyan or ep > 10 and colors.yellow or colors.red
    mon.setTextColor(colors.gray); mon.setCursorPos(1, row); mon.write(prefix)
    mon.setTextColor(col)
    mon.write("[" .. bar(state.energyStored or 0, state.energyCap or 1, bw) .. "]")
    mon.setTextColor(colors.white)
    mon.write(" " .. amtStr)
  end
  row = row + 1
  sep(row); row = row + 1

  -- Auto-rod rows (two rows: toggle+target, then step controls)
  -- Row 1: [Auto: ON] / [Manual]   Target: 10.0kFE/t   Rod:45%
  if at(row) then
    local autoOn = cfg.autoMode == true
    local tgt    = cfg.autoTarget or AUTO_TARGET_DEF
    local rodPct = (state.rodLevels and state.rodLevels[0]) or 0
    local aLabel = autoOn and "Auto: ON" or "Manual  "
    local aCol   = autoOn and colors.lime or colors.orange
    mon.setTextColor(aCol)
    mon.setCursorPos(1, row); mon.write(aLabel)
    addHit(monName, 1, row, #aLabel, row, "toggle_auto")
    if autoOn then
      local info = " Tgt:" .. fmtFEt(tgt) .. "  Rod:" .. rodPct .. "%"
      mon.setTextColor(colors.white)
      mon.write(info:sub(1, w - #aLabel))
    else
      local info = "  Rod:" .. rodPct .. "%"
      mon.setTextColor(colors.gray)
      mon.write(info:sub(1, w - #aLabel))
    end
  end
  row = row + 1

  -- Row 2: [<<] [-] <step size> [+] [>>]  (step cycle button on ends)
  if at(row) then
    local step     = AUTO_STEPS[autoStepIndex]
    local stepStr  = fmtStep(step)
    -- Layout: "Step:[<<][-] 500FE/t [+][>>]"
    -- [<<] cycles step down, [>>] cycles step up
    -- [-] decreases target by step, [+] increases
    local lblStr   = "Step:"
    local cycDnLbl = "[<<]"
    local minLbl   = "[-]"
    local plusLbl  = "[+]"
    local cycUpLbl = "[>>]"
    local midStr   = " " .. stepStr .. "FE/t "

    local x = 1
    mon.setTextColor(colors.gray)
    writeAt(mon, x, row, lblStr); x = x + #lblStr

    mon.setTextColor(colors.cyan)
    writeAt(mon, x, row, cycDnLbl)
    addHit(monName, x, row, x + #cycDnLbl - 1, row, "step_down")
    x = x + #cycDnLbl

    mon.setTextColor(colors.red)
    writeAt(mon, x, row, minLbl)
    addHit(monName, x, row, x + #minLbl - 1, row, "auto_minus")
    x = x + #minLbl

    mon.setTextColor(colors.yellow)
    writeAt(mon, x, row, midStr)
    x = x + #midStr

    mon.setTextColor(colors.lime)
    writeAt(mon, x, row, plusLbl)
    addHit(monName, x, row, x + #plusLbl - 1, row, "auto_plus")
    x = x + #plusLbl

    mon.setTextColor(colors.cyan)
    writeAt(mon, x, row, cycUpLbl)
    addHit(monName, x, row, x + #cycUpLbl - 1, row, "step_up")
  end
  row = row + 1

  -- Auto banner + footer credit
  if cfg.autoMode then
    -- Two-line footer: banner on h-1, credit on h (if room), else just banner on h
    local banner = "* Auto mode: rods adjust to match target FE/t"
    if h - row >= 2 then
      -- banner on h-1
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, h - 1)
      mon.write(banner:sub(1, w))
      -- credit on h
      local credit = "-- github.com/xransum"
      mon.setCursorPos(math.max(1, math.floor((w - #credit)/2)+1), h)
      mon.write(credit:sub(1, w))
    elseif at(h) then
      -- only room for one line — show banner
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, h)
      mon.write(banner:sub(1, w))
    end
  else
    if at(h) then
      local credit = "-- github.com/xransum"
      mon.setTextColor(colors.gray)
      mon.setCursorPos(math.max(1, math.floor((w - #credit)/2)+1), h)
      mon.write(credit:sub(1, w))
    end
  end
end

-- ── draw: rods panel ──────────────────────────────────────────────────────────

local function drawRods(mon, monName, startRow)
  local w, h     = mon.getSize()
  local rodCount = state.rodCount or 0
  local autoOn   = cfg.autoMode == true

  -- Title
  if startRow <= h then
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(1, startRow); mon.write("CONTROL RODS")

    if autoOn then
      -- Auto mode: show [> Manual] toggle on right
      local lbl = "[> Manual]"
      mon.setTextColor(colors.orange)
      writeAt(mon, w - #lbl + 1, startRow, lbl)
      addHit(monName, w - #lbl + 1, startRow, w, startRow, "toggle_auto")
    else
      -- Manual mode: [A+] [A-] all-rods + [> Auto] toggle
      local autoLbl = "[> Auto]"
      local allUpLbl = "[A+]"
      local allDnLbl = "[A-]"
      local autoX  = w - #autoLbl + 1
      local allDnX = autoX - #allDnLbl - 1
      local allUpX = allDnX - #allUpLbl - 1
      mon.setTextColor(colors.lime)
      writeAt(mon, allUpX, startRow, allUpLbl)
      addHit(monName, allUpX, startRow, allUpX + #allUpLbl - 1, startRow, "all_rods_up")
      mon.setTextColor(colors.red)
      writeAt(mon, allDnX, startRow, allDnLbl)
      addHit(monName, allDnX, startRow, allDnX + #allDnLbl - 1, startRow, "all_rods_down")
      mon.setTextColor(colors.lime)
      writeAt(mon, autoX, startRow, autoLbl)
      addHit(monName, autoX, startRow, w, startRow, "toggle_auto")
    end
  end

  local sepRow = startRow + 1
  if sepRow <= h then drawSep(mon, w, sepRow) end

  -- Footer
  local footerSepRow = h - 1
  local footerRow    = h
  if footerSepRow > sepRow then drawSep(mon, w, footerSepRow) end
  if footerRow <= h then
    if autoOn then
      local tgt    = cfg.autoTarget or AUTO_TARGET_DEF
      local rodPct = (state.rodLevels and state.rodLevels[0]) or 0
      mon.setTextColor(colors.yellow)
      mon.setCursorPos(1, footerRow)
      mon.write(("Auto: %s tgt rods@%d%%"):format(fmtFEt(tgt), rodPct):sub(1, w - 6))
    else
      mon.setTextColor(colors.orange)
      mon.setCursorPos(1, footerRow)
      mon.write("Manual mode")
    end
    addHit(monName, w-5, footerRow, w-3, footerRow, "rod_scroll_up")
    addHit(monName, w-2, footerRow, w,   footerRow, "rod_scroll_down")
  end

  -- Content area
  local contentStart = sepRow + 1
  local contentEnd   = footerSepRow > sepRow and footerSepRow - 1 or footerRow - 1
  local contentRows  = math.max(0, contentEnd - contentStart + 1)

  -- Column layout:
  -- Entry = "R000 45%" = 8 chars (auto) or "R000 45%[+][-]" = 14 chars (manual)
  -- Add 2-char gap between columns so labels never bleed into the next entry.
  local entryW  = autoOn and 8 or 14
  local gapW    = 2
  local cols    = math.max(1, math.floor((w + gapW) / (entryW + gapW)))
  local colW    = math.floor(w / cols)

  local rowsNeeded = math.ceil(rodCount / cols)
  local maxScroll  = math.max(0, rowsNeeded - contentRows)
  rodScrollOffset  = clamp(rodScrollOffset, 0, maxScroll)

  -- Scroll arrow active state
  if rowsNeeded > contentRows and footerRow <= h then
    mon.setTextColor(rodScrollOffset > 0 and colors.white or colors.gray)
    writeAt(mon, w - 5, footerRow, "[^]")
    mon.setTextColor(rodScrollOffset < maxScroll and colors.white or colors.gray)
    writeAt(mon, w - 2, footerRow, "[v]")
  end

  -- Draw rod grid
  for rowIdx = 0, contentRows - 1 do
    local gridRow   = rodScrollOffset + rowIdx
    local screenRow = contentStart + rowIdx
    if screenRow > contentEnd then break end

    for colIdx = 0, cols - 1 do
      local rodIdx = gridRow * cols + colIdx
      if rodIdx >= rodCount then break end

      local level  = (state.rodLevels and state.rodLevels[rodIdx]) or 0
      local xStart = colIdx * colW + 1

      -- R000 label (4 chars)
      mon.setTextColor(colors.cyan)
      writeAt(mon, xStart, screenRow, string.format("R%03d", rodIdx))

      -- Level " 45%" — space + up to 3 digits + % = 5 chars at xStart+4
      -- We write at xStart+4, giving colW-4 chars remaining before next col.
      -- Use %3d so 100 stays 3 digits: " 45%", "100%"
      local lc = level < 40 and colors.lime or level < 75 and colors.yellow or colors.red
      mon.setTextColor(lc)
      writeAt(mon, xStart + 4, screenRow, string.format("%3d%%", level))

      -- [+][-] only in manual mode, starting right after the 8-char entry
      if not autoOn then
        local plusX  = xStart + 8
        local minusX = xStart + 11
        if plusX + 2 <= xStart + colW - 1 then
          mon.setTextColor(colors.lime)
          writeAt(mon, plusX, screenRow, "[+]")
          addHit(monName, plusX, screenRow, plusX + 2, screenRow, "rod_up_" .. rodIdx)
        end
        if minusX + 2 <= xStart + colW - 1 then
          mon.setTextColor(colors.red)
          writeAt(mon, minusX, screenRow, "[-]")
          addHit(monName, minusX, screenRow, minusX + 2, screenRow, "rod_down_" .. rodIdx)
        end
      end
    end
  end
end

-- ── draw: scram panel ─────────────────────────────────────────────────────────

local function drawScram(mon, monName, startRow)
  local w, h   = mon.getSize()
  local rows   = h - startRow + 1  -- available rows
  local row    = startRow

  -- Helper: write a full-width button row
  local function btnRow(r, label, bg, fg)
    if r < startRow or r > h then return end
    local pad  = math.max(0, w - #label)
    local lpad = math.floor(pad / 2)
    local rpad = pad - lpad
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    mon.setCursorPos(1, r)
    mon.write(string.rep(" ", lpad) .. label:sub(1, w) .. string.rep(" ", rpad))
    mon.setBackgroundColor(colors.black)
  end

  if scramPending then
    -- Confirmation overlay — stack: warning / [CONFIRM] / gap? / [CANCEL]
    -- Minimum 2 rows (confirm + cancel); add title rows if space permits
    local confirmY = row + rows - 2  -- second-to-last row
    local cancelY  = row + rows - 1  -- last row

    -- Title rows if space allows
    if rows >= 4 then
      centered(mon, w, row,     "!! EMERGENCY !!",  colors.red)
      centered(mon, w, row + 1, "SHUTDOWN REACTOR",  colors.orange)
    elseif rows >= 3 then
      centered(mon, w, row, "!! SHUTDOWN !!", colors.red)
    end

    btnRow(confirmY, "[CONFIRM]", colors.green, colors.white)
    addHit(monName, 1, confirmY, w, confirmY, "scram_confirm")

    btnRow(cancelY, "[CANCEL]", colors.gray, colors.white)
    addHit(monName, 1, cancelY, w, cancelY, "scram_cancel")

  else
    -- Normal SCRAM panel — stack top-to-bottom, show what fits
    -- Always: [SCRAM!] button (most important)
    -- If space: status line above, ON/OFF below

    local scramY = row   -- default: scram at top

    if rows >= 4 then
      -- status + output + SCRAM + ON/OFF
      local statusStr = state.active and "REACTOR ONLINE" or "REACTOR OFFLINE"
      local statusCol = state.active and colors.lime or colors.gray
      centered(mon, w, row, statusStr, statusCol)

      local outStr = cfg.coolingMode == "active"
        and string.format("%.0f mB/t", state.energyLastTick or 0)
        or  fmtFEt(state.energyLastTick or 0)
      centered(mon, w, row + 1, "Output: " .. outStr, colors.white)

      scramY = row + 2

      -- ON / OFF on last row
      local onLabel  = "[ON]"
      local offLabel = "[OFF]"
      local onX  = math.floor(w / 4) - math.floor(#onLabel  / 2) + 1
      local offX = math.floor(3 * w / 4) - math.floor(#offLabel / 2) + 1
      mon.setTextColor(state.active and colors.lime or colors.gray)
      writeAt(mon, onX,  h, onLabel)
      addHit(monName, onX, h, onX + #onLabel - 1, h, "reactor_on")
      mon.setTextColor(state.active and colors.gray or colors.red)
      writeAt(mon, offX, h, offLabel)
      addHit(monName, offX, h, offX + #offLabel - 1, h, "reactor_off")

    elseif rows >= 3 then
      -- status + SCRAM + ON/OFF
      local statusStr = state.active and "ONLINE" or "OFFLINE"
      local statusCol = state.active and colors.lime or colors.gray
      centered(mon, w, row, statusStr, statusCol)
      scramY = row + 1

      local onLabel  = "[ON]"
      local offLabel = "[OFF]"
      local onX  = math.floor(w / 4) - math.floor(#onLabel  / 2) + 1
      local offX = math.floor(3 * w / 4) - math.floor(#offLabel / 2) + 1
      mon.setTextColor(state.active and colors.lime or colors.gray)
      writeAt(mon, onX,  h, onLabel)
      addHit(monName, onX, h, onX + #onLabel - 1, h, "reactor_on")
      mon.setTextColor(state.active and colors.gray or colors.red)
      writeAt(mon, offX, h, offLabel)
      addHit(monName, offX, h, offX + #offLabel - 1, h, "reactor_off")

    elseif rows >= 2 then
      -- SCRAM + ON/OFF, no status
      scramY = row
      local onLabel  = "[ON]"
      local offLabel = "[OFF]"
      local onX  = math.floor(w / 4) - math.floor(#onLabel  / 2) + 1
      local offX = math.floor(3 * w / 4) - math.floor(#offLabel / 2) + 1
      mon.setTextColor(state.active and colors.lime or colors.gray)
      writeAt(mon, onX,  h, onLabel)
      addHit(monName, onX, h, onX + #onLabel - 1, h, "reactor_on")
      mon.setTextColor(state.active and colors.gray or colors.red)
      writeAt(mon, offX, h, offLabel)
      addHit(monName, offX, h, offX + #offLabel - 1, h, "reactor_off")
    end

    -- SCRAM button fills from scramY to h-1 (or just scramY if only 1 row left)
    local scramRows = math.max(1, h - scramY - (rows >= 2 and 1 or 0))
    for r = scramY, scramY + scramRows - 1 do
      btnRow(r, r == scramY and "[SCRAM!]" or "", colors.red, colors.white)
    end
    -- register hit for all scram rows
    addHit(monName, 1, scramY, w, scramY + scramRows - 1, "scram_trigger")
  end
end

-- ── master draw ───────────────────────────────────────────────────────────────

local function drawAll()
  local tabMon = singleTabMon()

  if tabMon then
    -- Single monitor tab mode
    local monName = peripheral.getName(tabMon)
    local w, h    = tabMon.getSize()
    clearMon(tabMon)
    clearHitboxes(monName)
    drawTabStrip(tabMon, monName, w)
    -- Content starts at row 3
    local panel = PANELS[tabIndex]
    if     panel == PANEL_DASHBOARD then drawDashboard(tabMon, monName, 3)
    elseif panel == PANEL_RODS      then drawRods(tabMon, monName, 3)
    elseif panel == PANEL_SCRAM     then drawScram(tabMon, monName, 3)
    end
  else
    -- Multi-monitor mode
    local warnedMissing = {}
    for _, panel in ipairs(PANELS) do
      local name = cfg[panel]
      if name then
        if peripheral.isPresent(name) then
          local mon = peripheral.wrap(name)
          clearMon(mon)
          clearHitboxes(name)
          if     panel == PANEL_DASHBOARD then drawDashboard(mon, name, 1)
          elseif panel == PANEL_RODS      then drawRods(mon, name, 1)
          elseif panel == PANEL_SCRAM     then drawScram(mon, name, 1)
          end
        elseif not warnedMissing[name] then
          warnedMissing[name] = true
          printError("Monitor "..name.." ("..panel..") not found — panel disabled.")
        end
      end
    end

    -- Any monitors not assigned get a "not assigned" message
    local allMons = getMonitors()
    local assigned = {}
    for _, p in ipairs(PANELS) do
      if cfg[p] then assigned[cfg[p]] = true end
    end
    for _, m in ipairs(allMons) do
      if not assigned[m.name] then
        m.mon.setBackgroundColor(colors.black)
        m.mon.clear()
        m.mon.setTextColor(colors.gray)
        local w = m.mon.getSize()
        centered(m.mon, w, 2, "Not assigned", colors.gray)
        centered(m.mon, w, 3, "Run: reactor_monitor setup", colors.gray)
      end
    end
  end
end

-- ── action handler ────────────────────────────────────────────────────────────

local function handleAction(action)
  if action == "reactor_on" then
    pcall(reactor.setActive, true)
    playSound(SND_ON)

  elseif action == "reactor_off" then
    pcall(reactor.setActive, false)
    playSound(SND_OFF)

  elseif action == "toggle_auto" then
    cfg.autoMode = not cfg.autoMode
    saveCfg()
    playSound(cfg.autoMode and SND_ON or SND_OFF)

  elseif action == "auto_plus" then
    local step = AUTO_STEPS[autoStepIndex]
    cfg.autoTarget = (cfg.autoTarget or AUTO_TARGET_DEF) + step
    saveCfg()
    playSound(SND_ROD)

  elseif action == "auto_minus" then
    local step = AUTO_STEPS[autoStepIndex]
    cfg.autoTarget = math.max(0, (cfg.autoTarget or AUTO_TARGET_DEF) - step)
    saveCfg()
    playSound(SND_ROD)

  elseif action == "step_up" then
    autoStepIndex = (autoStepIndex % #AUTO_STEPS) + 1
    playSound(SND_ROD)

  elseif action == "step_down" then
    autoStepIndex = ((autoStepIndex - 2) % #AUTO_STEPS) + 1
    playSound(SND_ROD)

  elseif action == "all_rods_up" then
    -- [A+] = more output = withdraw rods = decrease insertion
    if cfg.autoMode then cfg.autoMode = false; saveCfg() end
    local lvl = state.rodLevels and state.rodLevels[0] or 50
    pcall(reactor.setAllControlRodLevels, clamp(lvl - ROD_STEP, 0, 100))
    playSound(SND_ROD)

  elseif action == "all_rods_down" then
    -- [A-] = less output = insert rods = increase insertion
    if cfg.autoMode then cfg.autoMode = false; saveCfg() end
    local lvl = state.rodLevels and state.rodLevels[0] or 50
    pcall(reactor.setAllControlRodLevels, clamp(lvl + ROD_STEP, 0, 100))
    playSound(SND_ROD)

  elseif action == "rod_scroll_up" then
    rodScrollOffset = math.max(0, rodScrollOffset - 1)

  elseif action == "rod_scroll_down" then
    rodScrollOffset = rodScrollOffset + 1  -- clamped in drawRods

  elseif action:sub(1, 7) == "rod_up_" then
    -- [+] = more output = withdraw rod = decrease insertion
    if cfg.autoMode then cfg.autoMode = false; saveCfg() end
    local idx = tonumber(action:sub(8))
    if idx then
      local lvl = (state.rodLevels and state.rodLevels[idx]) or 50
      pcall(reactor.setControlRodLevel, idx, clamp(lvl - ROD_STEP, 0, 100))
      playSound(SND_ROD)
    end

  elseif action:sub(1, 9) == "rod_down_" then
    -- [-] = less output = insert rod = increase insertion
    if cfg.autoMode then cfg.autoMode = false; saveCfg() end
    local idx = tonumber(action:sub(10))
    if idx then
      local lvl = (state.rodLevels and state.rodLevels[idx]) or 50
      pcall(reactor.setControlRodLevel, idx, clamp(lvl + ROD_STEP, 0, 100))
      playSound(SND_ROD)
    end

  elseif action:sub(1,4) == "tab_" then
    local i = tonumber(action:sub(5))
    if i then tabIndex = i end

  elseif action == "scram_trigger" then
    scramPending = true
    playSound(SND_ALARM)

  elseif action == "scram_confirm" then
    executeScram()

  elseif action == "scram_cancel" then
    cancelScram()
    playSound(SND_CONFIRM)
  end

  -- Always redraw after action
  pollReactor()
  drawAll()
end

-- ── interactive setup ─────────────────────────────────────────────────────────

local function runSetup()
  term.clear()
  term.setCursorPos(1,1)
  print("=== Reactor Monitor Setup ===")
  print("")

  -- Detect reactor info
  local rodCount    = pcall(reactor.getNumberOfControlRods) and reactor.getNumberOfControlRods() or "?"
  local activeCool  = pcall(reactor.isActivelyCooled) and reactor.isActivelyCooled() or false
  local defaultMode = activeCool and "active" or "passive"
  print("Reactor: extremereactor-reactorComputerPort")
  print("Rods: "..tostring(rodCount).."   Cooling: "..defaultMode.." (auto-detected)")
  print("Speaker: "..(speaker and "found" or "not found"))
  print("")

  -- List monitors (loop until at least one is found)
  local mons = getMonitors()
  while #mons == 0 do
    printError("No monitors found! Attach an Advanced Monitor and press Enter to retry.")
    read()
    mons = getMonitors()
  end

  print("Monitors detected:")
  for i, m in ipairs(mons) do
    local w, h = m.mon.getSize()
    print(string.format("  [%d] %-12s %d x %d", i, m.name, w, h))
  end
  print("")

  local newCfg = {}

  if #mons == 1 then
    print("1 monitor detected -> running in single-monitor tab mode.")
    newCfg.dashboard = mons[1].name
    newCfg.rods      = mons[1].name
    newCfg.scram     = mons[1].name
  else
    local function pickMon(label)
      while true do
        io.write("  "..label.." [1-"..#mons.."/none]: ")
        local line = read()
        if line == "" or line == "none" then return nil end
        local n = tonumber(line)
        if n and mons[n] then return mons[n].name end
        print("  Invalid choice.")
      end
    end
    print("Assign panels (Enter or 'none' to leave unassigned):")
    newCfg.dashboard = pickMon("Dashboard")
    newCfg.rods      = pickMon("Rods     ")
    newCfg.scram     = pickMon("SCRAM    ")
    print("")
  end

  -- Cooling mode
  io.write("Cooling mode [p=passive / a=active, default="..defaultMode:sub(1,1).."]: ")
  local modeIn = read()
  if modeIn == "a" then newCfg.coolingMode = "active"
  else newCfg.coolingMode = "passive" end

  -- Auto-rod target (default enabled)
  io.write("Auto-rod target FE/t [0=disabled, default="..AUTO_TARGET_DEF.."]: ")
  local tgtIn = read()
  local tgt = tonumber(tgtIn)
  if tgt and tgt == 0 then
    newCfg.autoTarget = AUTO_TARGET_DEF
    newCfg.autoMode   = false
  else
    newCfg.autoTarget = (tgt and tgt > 0) and tgt or AUTO_TARGET_DEF
    newCfg.autoMode   = true   -- on by default
  end

  cfg = newCfg
  saveCfg()
  playSound(SND_CONFIRM)
  print("")
  print("Config saved. Starting...")
  sleep(0.5)
  return true
end

-- ── CLI commands ──────────────────────────────────────────────────────────────

local args = { ... }

if args[1] == "setup" then
  runSetup()

elseif args[1] == "status" then
  pollReactor()
  print(string.format("Active:    %s", tostring(state.active)))
  print(string.format("FE/t:      %s", fmtFEt(state.energyLastTick or 0)))
  print(string.format("Stored:    %s / %s", fmtFE(state.energyStored or 0), fmtFE(state.energyCap or 0)))
  print(string.format("Fuel:      %d / %d mB (%d%%)", state.fuelAmt or 0, state.fuelMax or 0, pct(state.fuelAmt or 0, state.fuelMax or 1)))
  print(string.format("Waste:     %d mB", state.wasteAmt or 0))
  print(string.format("Fuel Temp: %dC   Casing: %dC", math.floor(state.fuelTemp or 0), math.floor(state.casingTemp or 0)))
  print(string.format("Rods:      %d", state.rodCount or 0))
  return

elseif args[1] == "scram" then
  print("SCRAM initiated from terminal.")
  executeScram()
  return

elseif args[1] == "on" then
  pcall(reactor.setActive, true)
  print("Reactor ON.")
  return

elseif args[1] == "off" then
  pcall(reactor.setActive, false)
  print("Reactor OFF.")
  return

elseif args[1] == "rods" then
  local lvl = tonumber(args[2])
  if lvl then
    lvl = clamp(lvl, 0, 100)
    pcall(reactor.setAllControlRodLevels, lvl)
    print("All rods set to "..lvl.."%")
  else
    printError("Usage: reactor rods <0-100>")
  end
  return

elseif args[1] == "mode" then
  if args[2] == "passive" or args[2] == "active" then
    cfg.coolingMode = args[2]
    saveCfg()
    print("Cooling mode set to "..args[2])
  else
    printError("Usage: reactor mode passive|active")
  end
  return
end

-- ── first-boot setup check ────────────────────────────────────────────────────

if not fs.exists(CFG_FILE) then
  local ok = runSetup()
  if not ok then return end
end

-- Reload cfg (may have been written by setup)
cfg = loadTable(CFG_FILE, {
  coolingMode = "passive",
  autoMode    = true,
  autoTarget  = AUTO_TARGET_DEF,
})

-- Migrate: if cfg exists but autoMode was never set, default to true
if cfg.autoMode == nil then
  cfg.autoMode = true
  saveCfg()
end

-- ── main event loop ───────────────────────────────────────────────────────────

print("Reactor monitor running. Press Ctrl+T to stop.")
print("Run 'reactor setup' to reconfigure.")

pollReactor()
drawAll()

local drawTimer = os.startTimer(DRAW_INTERVAL)
local autoTimer = os.startTimer(AUTO_INTERVAL)

while true do
  local evt, p1, p2, p3 = os.pullEvent()

  if evt == "timer" then
    if p1 == drawTimer then
      pollReactor()
      drawAll()
      drawTimer = os.startTimer(DRAW_INTERVAL)
    elseif p1 == autoTimer then
      autoAdjustRods()
      autoTimer = os.startTimer(AUTO_INTERVAL)
    end

  elseif evt == "monitor_touch" then
    local action = hitTest(p1, p2, p3)
    if action then handleAction(action) end

  elseif evt == "monitor_resize" or evt == "term_resize" then
    drawAll()
  end
end
