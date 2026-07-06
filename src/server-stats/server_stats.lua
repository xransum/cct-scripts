-- server_stats.lua
-- CC:Tweaked: displays world age and session uptime on an Advanced Monitor.
-- No ME Bridge required — uses only built-in CC:Tweaked time APIs.
--
-- "Session uptime" resets every time the script (re)starts, which happens on
-- every server restart, so it is a reliable proxy for server uptime.
--
-- Place an Advanced Monitor touching this computer and run, or use startup.lua.

local REFRESH = 5   -- seconds between display refreshes

-- ── peripheral setup ─────────────────────────────────────────────────────────

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach an Advanced Monitor to this computer.")
end

mon.setTextScale(0.5)

local speaker = peripheral.find("speaker")

local function playSound(inst, vol, pitch)
  if speaker then pcall(speaker.playNote, inst, vol or 1, pitch or 12) end
end

-- ── session start ─────────────────────────────────────────────────────────────
-- Captured once at script load; resets on every restart (including server restart).

local sessionStart = os.epoch("utc")   -- milliseconds

-- ── helpers ──────────────────────────────────────────────────────────────────

local function fmtDuration(ms)
  local s = math.floor(ms / 1000)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 0 then return ("%dd %dh %dm"):format(d, h, m) end
  if h > 0 then return ("%dh %dm %ds"):format(h, m, s) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

-- os.time() returns 0–24 where 0 = 6 AM Minecraft time
local function fmtGameTime()
  local t   = os.time()
  local hr  = math.floor((t + 6) % 24)
  local min = math.floor((t % 1) * 60)
  local ap  = hr < 12 and "AM" or "PM"
  local dh  = hr % 12; if dh == 0 then dh = 12 end
  return ("%d:%02d %s"):format(dh, min, ap)
end

local function timePeriod()
  local hr = (os.time() + 6) % 24
  if hr >=  5 and hr <  8 then return "dawn",      colors.orange  end
  if hr >=  8 and hr < 12 then return "morning",   colors.yellow  end
  if hr >= 12 and hr < 14 then return "noon",      colors.yellow  end
  if hr >= 14 and hr < 17 then return "afternoon", colors.yellow  end
  if hr >= 17 and hr < 20 then return "dusk",      colors.orange  end
  return "night", colors.blue
end

-- ── drawing ──────────────────────────────────────────────────────────────────

local function draw()
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local row = 1

  -- Helper: label on left, value right-aligned
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

  local function sep()
    if row > h then return end
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row)
    mon.write(string.rep("-", w))
    row = row + 1
  end

  -- Title
  local title = "SERVER STATS"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, row)
  mon.write(title)
  row = row + 1

  sep()

  -- World info
  local period, periodColor = timePeriod()
  rowLV("World Day",    ("Day %d"):format(os.day()),               colors.gray, colors.cyan)
  rowLV("In-Game Time", fmtGameTime() .. "  " .. period,          colors.gray, periodColor)

  sep()

  -- Session uptime
  rowLV("Session Uptime", fmtDuration(os.epoch("utc") - sessionStart), colors.gray, colors.lime)

  -- Footer credit
  if h > row then
    local credit = "-- github.com/xransum"
    mon.setTextColor(colors.gray)
    mon.setCursorPos(math.max(1, math.floor((w - #credit) / 2) + 1), h)
    mon.write(credit)
  end
end

-- ── main loop ─────────────────────────────────────────────────────────────────

print("server-stats running. Press Ctrl+T to stop.")
print("Monitor: " .. peripheral.getName(mon))

while true do
  draw()
  sleep(REFRESH)
end
