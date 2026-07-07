-- server_stats.lua
-- CC:Tweaked: world time, day/night bar, moon phase, and persistent uptime on a monitor.
-- No ME Bridge required.
--
-- Uptime is persisted to server_stats.cfg so it survives CC computer reboots.
-- A gap > REBOOT_THRESHOLD_MS between the last heartbeat and startup is treated
-- as a server restart: the previous session is credited and a new one begins.
-- Total uptime accumulates across all server sessions indefinitely.
--
-- Attach an Advanced Monitor and run, or use startup.lua.

local REFRESH             = 1          -- seconds between redraws (1s keeps the clock live)
local CFG_FILE            = "server_stats.cfg"
local SEED_FILE           = "server_stats_seed.cfg"  -- one-shot bootstrap; deleted after read
local REBOOT_THRESHOLD_MS = 90 * 1000  -- gap < 90 s → computer reboot; ≥ 90 s → server restart

-- ── peripheral ───────────────────────────────────────────────────────────────

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach an Advanced Monitor to this computer.")
end
mon.setTextScale(0.5)

-- ── cfg persistence ───────────────────────────────────────────────────────────

local function loadCfg()
  if not fs.exists(CFG_FILE) then return nil end
  local f = fs.open(CFG_FILE, "r")
  local raw = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, raw)
  return (ok and type(t) == "table") and t or nil
end

local function saveCfg(t)
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize(t))
  f.close()
end

-- ── server session tracking ───────────────────────────────────────────────────
-- On startup, compare now against the last heartbeat in the cfg file:
--   small gap  → CC computer was rebooted while server stayed up  → resume session
--   large gap  → server restarted (or first run)                  → credit + start fresh

local now = os.epoch("utc")
local cfg = loadCfg()
local totalAccumulatedMs, serverSessionStartMs

-- One-shot seed file: if present, use its serverStartMs to bootstrap the correct
-- server start epoch (e.g. injected after deploy to fix a wrong sessionStartMs).
-- The file is deleted immediately after reading so it only fires once.
local seedCfg
if fs.exists(SEED_FILE) then
  local sf = fs.open(SEED_FILE, "r")
  local raw = sf.readAll(); sf.close()
  local ok, t = pcall(textutils.unserialize, raw)
  seedCfg = (ok and type(t) == "table") and t or nil
  fs.delete(SEED_FILE)
  print("Seed file applied and removed.")
end

if seedCfg and seedCfg.serverStartMs then
  -- Seed override: use the provided epoch as the true server session start.
  -- Keep any previously accumulated total; do not credit the (wrong) old session.
  totalAccumulatedMs   = (cfg and cfg.totalMs or 0)
  serverSessionStartMs = seedCfg.serverStartMs
elseif cfg and cfg.lastHeartbeatMs and (now - cfg.lastHeartbeatMs) < REBOOT_THRESHOLD_MS then
  -- Computer reboot: resume the existing server session
  totalAccumulatedMs   = cfg.totalMs        or 0
  serverSessionStartMs = cfg.sessionStartMs or now
else
  -- Server restart or first run: credit previous session up to its last heartbeat
  local prevMs = 0
  if cfg and cfg.sessionStartMs and cfg.lastHeartbeatMs then
    prevMs = math.max(0, cfg.lastHeartbeatMs - cfg.sessionStartMs)
  end
  totalAccumulatedMs   = (cfg and cfg.totalMs or 0) + prevMs
  serverSessionStartMs = now
end

-- ── constants ────────────────────────────────────────────────────────────────

-- Minecraft moon cycles through 8 phases; os.day() % 8 gives the index.
local MOON_PHASES = {
  "Full Moon",       -- 0
  "Waning Gibbous",  -- 1
  "Last Quarter",    -- 2
  "Waning Crescent", -- 3
  "New Moon",        -- 4
  "Waxing Crescent", -- 5
  "First Quarter",   -- 6
  "Waxing Gibbous",  -- 7
}

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Format a millisecond duration as a human-readable string
local function fmtDuration(ms)
  if not ms or ms < 0 then ms = 0 end
  local s = math.floor(ms / 1000)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 0 then return ("%dd %dh %dm"):format(d, h, m) end
  if h > 0 then return ("%dh %dm %ds"):format(h, m, s) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

-- Formatted in-game clock: "6:42 AM"
local function fmtGameTime()
  local t   = os.time()
  local hr  = math.floor((t + 6) % 24)
  local min = math.floor((t % 1) * 60)
  local ap  = hr < 12 and "AM" or "PM"
  local dh  = hr % 12; if dh == 0 then dh = 12 end
  return ("%d:%02d %s"):format(dh, min, ap)
end

-- Period name + colour for the current time of day
local function timePeriod()
  local hr = (os.time() + 6) % 24
  if hr >=  5 and hr <  7 then return "Dawn",      colors.orange end
  if hr >=  7 and hr < 12 then return "Morning",   colors.yellow end
  if hr >= 12 and hr < 13 then return "Noon",      colors.yellow end
  if hr >= 13 and hr < 17 then return "Afternoon", colors.yellow end
  if hr >= 17 and hr < 20 then return "Dusk",      colors.orange end
  return "Night", colors.blue
end

-- Next noteworthy event and real-time seconds until it.
-- os.time(): 0=6AM, 6=Noon, 12=6PM, 18=Midnight, 24=6AM
local function nextEvent()
  local t = os.time()
  local events = {
    { at = 0,  name = "Dawn"     },
    { at = 6,  name = "Noon"     },
    { at = 12, name = "Dusk"     },
    { at = 18, name = "Midnight" },
  }
  for _, ev in ipairs(events) do
    if ev.at > t then
      local secs = math.max(0, math.floor((ev.at - t) * 50))
      return ev.name, math.floor(secs / 60), secs % 60
    end
  end
  -- all past → wrap to next dawn
  local secs = math.max(0, math.floor((24 - t) * 50))
  return "Dawn", math.floor(secs / 60), secs % 60
end

-- Background colour for a position on the day/night bar.
-- barFrac: 0.0 (left = 6AM) .. 1.0 (right = 6AM next day)
local function barBg(barFrac)
  local hour = barFrac * 24           -- 0 = 6AM in MC time
  local realHr = (hour + 6) % 24      -- 0 = midnight in 24h clock
  if realHr <  5 then return colors.blue   end   -- pre-dawn
  if realHr <  7 then return colors.orange end   -- dawn
  if realHr < 17 then return colors.yellow end   -- day
  if realHr < 20 then return colors.orange end   -- dusk
  return colors.blue                             -- night
end

-- ── draw ─────────────────────────────────────────────────────────────────────

local function draw()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local row = 1

  local function at(r) return row <= r and r <= h end

  local function sep(r)
    if not at(r) then return end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, r)
    mon.write(string.rep("-", w))
  end

  local function centered(r, text, col)
    if not at(r) then return end
    mon.setTextColor(col or colors.white)
    mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), r)
    mon.write(text:sub(1, w))
  end

  local function lv(r, label, value, lc, vc)
    if not at(r) then return end
    mon.setTextColor(lc or colors.gray)
    mon.setCursorPos(1, r)
    mon.write(label)
    mon.setTextColor(vc or colors.white)
    local vx = math.max(#label + 2, w - #value + 1)
    mon.setCursorPos(vx, r)
    mon.write(value:sub(1, w - vx + 1))
  end

  -- ── title ──────────────────────────────────────────────────────────────────
  centered(1, "SERVER STATS", colors.yellow)
  sep(2)

  -- ── time display ───────────────────────────────────────────────────────────
  local timeStr           = fmtGameTime()
  local period, periodCol = timePeriod()

  if h >= 16 then
    -- Tall monitor: give the time its own row, period on the next
    centered(3, timeStr,  periodCol)
    centered(4, period,   periodCol)
  else
    centered(3, timeStr .. "   " .. period, periodCol)
  end

  -- ── world day + moon phase ─────────────────────────────────────────────────
  local moonStr = MOON_PHASES[(os.day() % 8) + 1]
  local dayRow  = h >= 16 and 5 or 4
  lv(dayRow, ("Day %d"):format(os.day()), moonStr, colors.cyan, colors.gray)

  sep(dayRow + 1)

  -- ── day / night progress bar ───────────────────────────────────────────────
  local barRow    = dayRow + 2
  local labelRow  = barRow + 1
  local postBarSep = labelRow + 1

  if at(barRow) then
    local t         = os.time()       -- 0 = 6AM
    local markerX   = math.max(1, math.min(w, math.floor(t / 24 * w) + 1))
    local isDaytime = (t >= 0 and t < 12)

    mon.setCursorPos(1, barRow)
    for col = 1, w do
      local bg = barBg((col - 1) / w)
      mon.setBackgroundColor(bg)
      if col == markerX then
        mon.setTextColor(isDaytime and colors.white or colors.lightGray)
        mon.write(isDaytime and "\x0F" or "\x07")   -- ☼ sun / • moon
      else
        mon.write(" ")
      end
    end
    mon.setBackgroundColor(colors.black)
  end

  if at(labelRow) then
    -- Labels at 0 % (6AM), 50 % (6PM/Midnight line), 100 % (6AM)
    -- also show Noon at 25%
    local lDawn  = "6AM"
    local lNoon  = "Noon"
    local l6pm   = "6PM"
    local lDawn2 = "6AM"
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, labelRow)
    mon.write(lDawn)
    local noonX = math.floor(w * 0.25) - math.floor(#lNoon / 2) + 1
    if noonX > #lDawn + 1 then
      mon.setCursorPos(noonX, labelRow)
      mon.write(lNoon)
    end
    local pmX = math.floor(w * 0.5) - math.floor(#l6pm / 2) + 1
    if pmX > noonX + #lNoon + 1 then
      mon.setCursorPos(pmX, labelRow)
      mon.write(l6pm)
    end
    mon.setCursorPos(w - #lDawn2 + 1, labelRow)
    mon.write(lDawn2)
  end

  sep(postBarSep)

  -- ── next event countdown ───────────────────────────────────────────────────
  local evRow = postBarSep + 1
  if at(evRow) then
    local evName, em, es = nextEvent()
    lv(evRow, "Next:", ("%s in %dm %ds"):format(evName, em, es), colors.gray, colors.cyan)
  end

  sep(evRow + 1)

  -- ── uptime ────────────────────────────────────────────────────────────────
  local uptRow     = evRow + 2
  local serverUpMs = os.epoch("utc") - serverSessionStartMs
  local totalUpMs  = totalAccumulatedMs + serverUpMs
  lv(uptRow,     "Server up:", fmtDuration(serverUpMs), colors.gray, colors.lime)
  lv(uptRow + 1, "Total up:",  fmtDuration(totalUpMs),  colors.gray, colors.cyan)

  -- ── footer ────────────────────────────────────────────────────────────────
  local credit = "-- github.com/xransum"
  mon.setTextColor(colors.gray)
  mon.setCursorPos(math.max(1, math.floor((w - #credit) / 2) + 1), h)
  mon.write(credit:sub(1, w))
end

-- ── main loop ─────────────────────────────────────────────────────────────────

print("server-stats running. Press Ctrl+T to stop.")
print("Monitor: " .. peripheral.getName(mon))

while true do
  draw()
  saveCfg({
    totalMs         = totalAccumulatedMs,
    sessionStartMs  = serverSessionStartMs,
    lastHeartbeatMs = os.epoch("utc"),
  })
  sleep(REFRESH)
end
