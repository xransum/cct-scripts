-- player_stats.lua
-- CC:Tweaked: live player roster + persistent playtime and death counter.
--
-- Requires:
--   Advanced Peripherals Player Detector  (peripheral: player_detector / playerDetector)
--   Advanced Monitor
--
-- Optional (improves death detection):
--   Advanced Peripherals Chat Box  (peripheral: chatBox)
--   Speaker
--
-- Death detection uses two methods simultaneously:
--   1. Health polling — catches death whenever health drops to 0 between 2s polls.
--   2. Chat Box system messages — AP fires a "chat" event with empty username for
--      server/death messages in some versions; parses if the message starts with a
--      known player name as an additional signal.
-- Either method independently increments the counter; duplicates within a 5-second
-- window are suppressed.
--
-- Playtime is tracked via playerJoin / playerLeave events.  A heartbeat is written
-- every poll cycle so that in-progress sessions are credited even if the server
-- crashes; on restart the previous session is credited up to the last heartbeat,
-- losing at most POLL_SECS of play time.  A gap < REBOOT_THRESHOLD_MS between the
-- last heartbeat and now is treated as a CC computer reboot (server still running)
-- and the session is resumed transparently.
--
-- Display shows a single ROSTER view (all known players, online first) toggleable
-- to a STATS leaderboard sorted by deaths.
--
-- Config: set playerDetMaxRange = -1 in config/advancedperipherals.toml to allow
--         the detector to see players anywhere on the server (not just nearby).

local SAVE_FILE            = "player_stats.cfg"
local POLL_SECS            = 2          -- seconds between health polls
local DRAW_SECS            = 1          -- seconds between display refreshes (keeps timers live)
local DEDUPE_MS            = 5000       -- ms window to suppress duplicate death counts
local REBOOT_THRESHOLD_MS  = 90 * 1000  -- gap < 90 s → CC reboot (server up); ≥ 90 s → server restart

-- ── helpers ──────────────────────────────────────────────────────────────────

local function saveTable(path, data)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(data))
  f.close()
end

local function loadTable(path, default)
  if not fs.exists(path) then saveTable(path, default); return default end
  local f = fs.open(path, "r")
  local raw = f.readAll(); f.close()
  local ok, r = pcall(textutils.unserialize, raw)
  if ok and type(r) == "table" then return r end
  saveTable(path, default); return default
end

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  return ok and res or nil
end

local function truncate(str, maxLen)
  if #str <= maxLen then return str end
  return str:sub(1, maxLen - 1) .. ">"
end

local function fmtDim(dim)
  if not dim then return "?" end
  -- Strip "minecraft:" prefix and shorten well-known names
  dim = dim:gsub("^minecraft:", "")
  if dim == "the_nether" then return "nether" end
  if dim == "the_end"    then return "end"    end
  if dim == "overworld"  then return "overworld" end
  -- Modded: take last segment after any colon or slash
  return (dim:match("[:/]([^:/]+)$") or dim):sub(1, 10)
end

local function fmtDuration(ms)
  if not ms or ms < 0 then return "0s" end
  local s = math.floor(ms / 1000)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 0 then return ("%dd %dh"):format(d, h) end
  if h > 0 then return ("%dh %dm"):format(h, m) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

-- ── peripheral setup ─────────────────────────────────────────────────────────

local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
if not detector then
  error("No Player Detector found. Place an AP Player Detector touching this computer.")
end

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach an Advanced Monitor.")
end

mon.setTextScale(0.5)
local monName = peripheral.getName(mon)

local chatBox = peripheral.find("chatBox")
local speaker = peripheral.find("speaker")

local function playSound(inst, vol, pitch)
  if speaker then pcall(speaker.playNote, inst, vol or 1, pitch or 12) end
end

-- ── state ─────────────────────────────────────────────────────────────────────

-- Persisted to disk: [name] = { deaths=N, totalMs=N, lastSeen=epoch }
local persist = {}

-- Runtime only
local sessionStart = {}   -- [name] = epoch when this session began
local prevHealth   = {}   -- [name] = health at last poll (nil = not yet polled)
local playerData   = {}   -- [name] = getPlayer() result, cached between polls
local lastDeath    = {}   -- [name] = epoch of last recorded death (for deduplication)
local knownNames   = {}   -- set: all names we have ever seen

local view = "roster"   -- "roster" | "stats"
local switchRow = 1       -- monitor row that toggles the view

-- ── persistence ───────────────────────────────────────────────────────────────

local function ensurePlayer(name)
  if not persist[name] then
    persist[name] = { deaths = 0, totalMs = 0, lastSeen = os.epoch("utc") }
  end
  knownNames[name] = true
end

local function saveData()
  -- Snapshot persist + live sessionStart timestamps into a single table.
  -- _savedAt lets loadData() distinguish a CC computer reboot from a server restart.
  local out = { _savedAt = os.epoch("utc") }
  for name, data in pairs(persist) do
    out[name] = {
      deaths        = data.deaths,
      totalMs       = data.totalMs,
      lastSeen      = data.lastSeen,
      sessionStartMs = sessionStart[name],   -- nil when offline → absent from file
    }
  end
  saveTable(SAVE_FILE, out)
end

local function loadData()
  local saved    = loadTable(SAVE_FILE, {})
  local savedAt  = saved._savedAt          -- nil for old-format files → treated as server restart
  local now      = os.epoch("utc")
  local isReboot = savedAt ~= nil and (now - savedAt) < REBOOT_THRESHOLD_MS

  for name, data in pairs(saved) do
    if name == "_savedAt" then
      -- metadata key, skip
    elseif type(name) == "string" and type(data) == "table" then
      persist[name] = {
        deaths   = data.deaths   or 0,
        totalMs  = data.totalMs  or 0,
        lastSeen = data.lastSeen or now,
      }
      knownNames[name] = true

      if data.sessionStartMs then
        if isReboot then
          -- CC computer reboot: server kept running, resume the open session
          sessionStart[name] = data.sessionStartMs
        else
          -- Server restart: credit playtime up to the last heartbeat
          persist[name].totalMs = persist[name].totalMs +
            math.max(0, savedAt - data.sessionStartMs)
        end
      end
    end
  end
end

-- ── death recording ───────────────────────────────────────────────────────────

local function recordDeath(name, source)
  ensurePlayer(name)
  local now = os.epoch("utc")
  -- Deduplicate: ignore if another method already recorded this death recently
  if lastDeath[name] and (now - lastDeath[name]) < DEDUPE_MS then return end
  lastDeath[name] = now
  persist[name].deaths = persist[name].deaths + 1
  saveData()
  playSound("bass", 3, 4)
  print(("[death] %s  (#%d via %s)"):format(name, persist[name].deaths, source or "?"))
end

-- ── session tracking ──────────────────────────────────────────────────────────

local function onJoin(name)
  ensurePlayer(name)
  sessionStart[name] = os.epoch("utc")
  prevHealth[name]   = nil   -- reset so first poll doesn't false-fire
  print(("[join]  %s"):format(name))
end

local function onLeave(name)
  ensurePlayer(name)
  if sessionStart[name] then
    persist[name].totalMs = persist[name].totalMs + (os.epoch("utc") - sessionStart[name])
    sessionStart[name] = nil
  end
  persist[name].lastSeen = os.epoch("utc")
  playerData[name] = nil
  prevHealth[name] = nil
  saveData()
  print(("[leave] %s"):format(name))
end

local function initOnline()
  local online = safeCall(detector.getOnlinePlayers) or {}
  local onlineSet = {}
  for _, name in ipairs(online) do onlineSet[name] = true end

  -- If we resumed a session for a player who is no longer actually online
  -- (they left during the downtime), credit their time and clear the session.
  for name in pairs(sessionStart) do
    if not onlineSet[name] then
      ensurePlayer(name)
      persist[name].totalMs  = persist[name].totalMs + (os.epoch("utc") - sessionStart[name])
      persist[name].lastSeen = os.epoch("utc")
      sessionStart[name]     = nil
    end
  end

  -- Ensure all currently online players have a session start.
  -- Resumed players already have sessionStart set; newly seen players get now.
  for _, name in ipairs(online) do
    ensurePlayer(name)
    if not sessionStart[name] then
      sessionStart[name] = os.epoch("utc")
    end
    local data = safeCall(detector.getPlayer, name)
    if data then
      playerData[name] = data
      prevHealth[name] = data.health
    end
  end
end

-- ── health poll ───────────────────────────────────────────────────────────────

local function pollHealth()
  local online = safeCall(detector.getOnlinePlayers) or {}
  for _, name in ipairs(online) do
    ensurePlayer(name)
    local data = safeCall(detector.getPlayer, name)
    if data then
      playerData[name] = data
      local h    = data.health or 0
      local prev = prevHealth[name]
      -- Death: health was above 0 last poll, now 0
      if prev and prev > 0 and h == 0 then
        recordDeath(name, "health")
      end
      prevHealth[name] = h
    end
  end
end

-- ── chat death detection ──────────────────────────────────────────────────────
-- AP Chat Box fires "chat" with username="" for system/server messages in some
-- versions. Death messages always begin with the dying player's name.

local function parseChatDeath(username, message)
  if username and username ~= "" then return end  -- player chat, not a death msg
  if not message then return end
  for name in pairs(knownNames) do
    if message:sub(1, #name) == name then
      recordDeath(name, "chat")
      return
    end
  end
end

-- ── drawing ───────────────────────────────────────────────────────────────────

local function drawHealthBar(row, col, barW, health, maxHealth)
  local pct    = (maxHealth and maxHealth > 0) and (health / maxHealth) or 0
  local filled = math.floor(pct * barW)
  local bg     = pct > 0.6 and colors.green
              or pct > 0.3 and colors.yellow
              or colors.red
  mon.setCursorPos(col, row)
  mon.setBackgroundColor(bg)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", barW - filled))
  mon.setBackgroundColor(colors.black)
end

local function drawRoster()
  local w, h = mon.getSize()
  local BAR_W = math.max(6, math.floor(w * 0.28))
  local now   = os.epoch("utc")

  -- Build two sorted lists: online (alpha) then offline (most recently seen first)
  local online, offline = {}, {}
  for name, data in pairs(persist) do
    local isOnline = sessionStart[name] ~= nil
    local totalMs  = data.totalMs + (isOnline and (now - sessionStart[name]) or 0)
    local entry = { name=name, isOnline=isOnline, totalMs=totalMs,
                    deaths=data.deaths, lastSeen=data.lastSeen }
    if isOnline then online[#online+1] = entry
    else             offline[#offline+1] = entry end
  end
  table.sort(online,  function(a,b) return a.name:lower() < b.name:lower() end)
  table.sort(offline, function(a,b) return a.lastSeen > b.lastSeen end)

  local row = 1

  -- ── title ──────────────────────────────────────────────────────────────────
  switchRow = row
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, row); mon.write("PLAYERS")

  local onlineTag = "(" .. #online .. " online)"
  mon.setTextColor(colors.lime)
  mon.setCursorPos(math.floor((w - #onlineTag) / 2) + 1, row)
  mon.write(onlineTag)

  local toggle = "[stats >]"
  mon.setTextColor(colors.cyan)
  mon.setCursorPos(w - #toggle + 1, row); mon.write(toggle)
  row = row + 1

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1

  local function needRows(n) return row + n - 1 <= h - 1 end

  -- ── online players (2 rows each) ───────────────────────────────────────────
  for i, p in ipairs(online) do
    if not needRows(2) then break end

    local data    = playerData[p.name] or {}
    local dim     = fmtDim(data.dimension)
    local health  = data.health    or 0
    local maxHP   = data.maxHealth or 20
    local sessStr = fmtDuration(now - (sessionStart[p.name] or now))
    local totStr  = fmtDuration(p.totalMs)

    -- Row 1: + Name   dim   session
    local right1  = dim .. "  " .. sessStr
    local nameMax = w - 2 - #right1 - 1
    mon.setTextColor(colors.lime);  mon.setCursorPos(1, row); mon.write("+")
    mon.setTextColor(colors.white); mon.setCursorPos(2, row); mon.write(truncate(p.name, nameMax))
    mon.setTextColor(colors.gray);  mon.setCursorPos(w - #right1 + 1, row); mon.write(right1)
    row = row + 1

    -- Row 2: [health bar]  hp  deaths  total
    drawHealthBar(row, 2, BAR_W, health, maxHP)
    local hpStr    = ("  %d/%d hp"):format(math.floor(health), math.floor(maxHP))
    local deathStr = "(" .. tostring(p.deaths) .. ")"
    local right2   = deathStr .. "  " .. totStr
    mon.setTextColor(colors.white)
    mon.setCursorPos(2 + BAR_W, row)
    mon.write(truncate(hpStr, w - BAR_W - 2 - #right2 - 2))
    mon.setTextColor(colors.red);
    mon.setCursorPos(w - #totStr - #deathStr - 1, row); mon.write(deathStr)
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(w - #totStr + 1, row); mon.write(totStr)
    row = row + 1

    -- separator between online players (not after last)
    if needRows(1) and i < #online then
      mon.setTextColor(colors.gray)
      mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1
    end
  end

  -- ── divider between online and offline sections ────────────────────────────
  if #online > 0 and #offline > 0 and needRows(1) then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1
  end

  -- ── offline players (1 row each) ──────────────────────────────────────────
  for _, p in ipairs(offline) do
    if not needRows(1) then break end

    local agoStr   = fmtDuration(now - p.lastSeen) .. " ago"
    local totStr   = fmtDuration(p.totalMs)
    local deathStr = "(" .. tostring(p.deaths) .. ")"
    local right1   = agoStr .. "  " .. deathStr .. "  " .. totStr
    local nameMax  = w - 2 - #right1 - 1

    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row); mon.write(" ")
    mon.setCursorPos(2, row); mon.write(truncate(p.name, nameMax))
    mon.setCursorPos(w - #totStr - #deathStr - #agoStr - 3, row); mon.write(agoStr)
    mon.setTextColor(colors.red)
    mon.setCursorPos(w - #totStr - #deathStr - 1, row); mon.write(deathStr)
    mon.setTextColor(colors.gray)
    mon.setCursorPos(w - #totStr + 1, row); mon.write(totStr)
    row = row + 1
  end

  -- ── empty state ────────────────────────────────────────────────────────────
  if #online == 0 and #offline == 0 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(2, row); mon.write("No players seen yet.")
  end

  -- ── footer ─────────────────────────────────────────────────────────────────
  local note = chatBox and "death: chat+health" or "death: health poll"
  mon.setTextColor(colors.gray)
  mon.setCursorPos(w - #note + 1, h); mon.write(note)
end

local function drawStats()
  local w, h = mon.getSize()

  -- Build sorted list (by deaths desc, then name)
  local players = {}
  for name, data in pairs(persist) do
    local isOnline = sessionStart[name] ~= nil
    local totalMs  = data.totalMs
    if isOnline and sessionStart[name] then
      totalMs = totalMs + (os.epoch("utc") - sessionStart[name])
    end
    players[#players + 1] = {
      name     = name,
      deaths   = data.deaths,
      totalMs  = totalMs,
      isOnline = isOnline,
      lastSeen = data.lastSeen,
    }
  end
  table.sort(players, function(a, b)
    if a.deaths ~= b.deaths then return a.deaths > b.deaths end
    return a.name:lower() < b.name:lower()
  end)

  local row = 1

  -- Title row (tap to switch view)
  switchRow = row
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, row)
  mon.write("PLAYER STATS")

  local toggle = "[< roster]"
  mon.setTextColor(colors.cyan)
  mon.setCursorPos(w - #toggle + 1, row)
  mon.write(toggle)
  row = row + 1

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1

  if #players == 0 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(2, row); mon.write("No data yet."); row = row + 1
  else
    for _, p in ipairs(players) do
      if row > h - 1 then break end

      -- Online indicator
      mon.setTextColor(p.isOnline and colors.lime or colors.gray)
      mon.setCursorPos(1, row)
      mon.write(p.isOnline and "+" or " ")

      -- Deaths
      local deathStr = "(" .. tostring(p.deaths) .. ")"
      -- Time
      local timeStr  = fmtDuration(p.totalMs)
      -- Name (fills remaining space)
      local nameMax  = w - 1 - #deathStr - 1 - #timeStr - 2
      mon.setTextColor(colors.white)
      mon.setCursorPos(2, row)
      mon.write(truncate(p.name, nameMax))

      mon.setTextColor(colors.red)
      mon.setCursorPos(w - #timeStr - #deathStr - 1, row)
      mon.write(deathStr)

      mon.setTextColor(colors.gray)
      mon.setCursorPos(w - #timeStr + 1, row)
      mon.write(timeStr)

      row = row + 1
    end
  end

  -- Footer
  if h >= row then
    local note = "+ = online  all-time playtime"
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, h)
    mon.write(truncate(note, w))
  end
end

local function drawMonitor()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  if view == "roster" then
    drawRoster()
  else
    drawStats()
  end
end

-- ── main ──────────────────────────────────────────────────────────────────────

loadData()
initOnline()
drawMonitor()

print("player-stats running.")
print("Detector: " .. peripheral.getName(detector))
print("Monitor:  " .. peripheral.getName(mon))
print("ChatBox:  " .. (chatBox and peripheral.getName(chatBox) or "none"))
print("Speaker:  " .. (speaker and peripheral.getName(speaker) or "none"))
print("Known players: " .. (function()
  local n = 0; for _ in pairs(persist) do n = n + 1 end; return n
end)())
print("Config tip: set playerDetMaxRange=-1 in advancedperipherals.toml for server-wide detection.")

local pollTimer = os.startTimer(POLL_SECS)
local drawTimer = os.startTimer(DRAW_SECS)

while true do
  local ev = { os.pullEvent() }
  local event = ev[1]

  if event == "timer" then
    if ev[2] == pollTimer then
      pollHealth()
      saveData()      -- heartbeat: preserves in-progress sessions across crashes
      drawMonitor()
      pollTimer = os.startTimer(POLL_SECS)
    elseif ev[2] == drawTimer then
      drawMonitor()   -- keeps session timers counting up live
      drawTimer = os.startTimer(DRAW_SECS)
    end

  elseif event == "playerJoin" then
    -- ev = { "playerJoin", username, dimension }
    onJoin(ev[2])
    drawMonitor()

  elseif event == "playerLeave" then
    -- ev = { "playerLeave", username, dimension }
    onLeave(ev[2])
    drawMonitor()

  elseif event == "chat" then
    -- ev = { "chat", username, message, uuid, isHidden }
    -- username is empty/nil for system messages including death messages
    parseChatDeath(ev[2], ev[3])
    -- No redraw needed here; drawTimer will catch it within 1s

  elseif event == "monitor_touch" then
    -- ev = { "monitor_touch", side, x, y }
    if ev[2] == monName and ev[4] == switchRow then
      view = (view == "roster") and "stats" or "roster"
      drawMonitor()
    end
  end
end
