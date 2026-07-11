-- geo_ore_finder.lua
-- Pocket computer Geo Scanner ore finder.
-- Scans for ores within range, groups by type, and shows the relative
-- direction + distance to the nearest block of each type so you can
-- walk straight to it.  GPS coordinates are shown when GPS is available.
--
-- Usage:
--   geo_ore_finder                     default specials, no auto-refresh
--   geo_ore_finder 3                   auto-refresh every 3 seconds
--   geo_ore_finder 3 diamond emerald   auto + extra special substrings
--   geo_ore_finder diamond             extra specials, no auto-refresh
--   (first numeric arg 1-60 = auto interval in seconds; rest = substrings)
--
-- Controls:
--   R           manual rescan
--   A           cycle auto-refresh interval (off → 2s → 3s → 5s → 10s)
--   Q           quit
--   Up / W      scroll up
--   Down / S    scroll down
--
-- Requirements:
--   Advanced Pocket Computer
--   AP Geo Scanner pocket upgrade

-- ── config ────────────────────────────────────────────────────────────────────

local SCAN_RADIUS = 16   -- max free=8, max paid=64 (server config); higher costs more FE

-- Highlighted red and sorted to the top of results
local SPECIAL = {
  "allthemodium",
  "vibranium",
  "unobtainium",
  "ancient_debris",
}

-- Values for [A] cycling: 0 = off
local AUTO_OPTIONS = { 0, 2, 3, 5, 10 }

-- ── arg parsing ───────────────────────────────────────────────────────────────
-- First arg that is a number in 1-60 → initial auto interval.
-- All remaining / non-numeric args → appended to SPECIAL list.

local autoInterval = 0
local extraTerms   = {}

for _, a in ipairs({ ... }) do
  local n = tonumber(a)
  if n and n >= 1 and n <= 60 and autoInterval == 0 then
    autoInterval = n
  else
    local s = a:lower()
    SPECIAL[#SPECIAL + 1] = s
    extraTerms[#extraTerms + 1] = s
  end
end

-- ── peripheral ───────────────────────────────────────────────────────────────

local scanner = peripheral.find("geoScanner") or peripheral.find("geo_scanner")
if not scanner then
  print("No geo scanner found.")
  print("Run peripheral.getNames() to confirm")
  print("the upgrade is attached.")
  return
end

local W, H = term.getSize()

-- ── helpers ───────────────────────────────────────────────────────────────────

local function isSpecial(name)
  local lname = name:lower()
  for _, s in ipairs(SPECIAL) do
    if lname:find(s, 1, true) then return true end
  end
  return false
end

local function isOre(name)
  return name:lower():find("ore", 1, true) ~= nil
end

local function dist3(x, y, z)
  return math.sqrt(x * x + y * y + z * z)
end

-- "3W 5↓ 2N" style direction string from relative offset
local function dirStr(dx, dy, dz)
  local parts = {}
  if dx ~= 0 then parts[#parts + 1] = math.abs(dx) .. (dx > 0 and "E" or "W") end
  if dy ~= 0 then parts[#parts + 1] = math.abs(dy) .. (dy > 0 and "\x18" or "\x19") end
  if dz ~= 0 then parts[#parts + 1] = math.abs(dz) .. (dz > 0 and "S" or "N") end
  return #parts > 0 and table.concat(parts, " ") or "here"
end

-- "allthemodium:allthemodium_ore" -> "Allthemodium Ore"
local function prettyName(fullName)
  local id = fullName:match(":(.+)$") or fullName
  return (id:gsub("_", " "):gsub("(%a)([%w]*)", function(a, b)
    return a:upper() .. b:lower()
  end))
end

-- ── auto-refresh timer ───────────────────────────────────────────────────────

local autoTimer = nil

local function resetAutoTimer()
  autoTimer = nil
  if autoInterval > 0 then
    autoTimer = os.startTimer(autoInterval)
  end
end

local function nextAutoOption()
  for i, v in ipairs(AUTO_OPTIONS) do
    if v == autoInterval then
      return AUTO_OPTIONS[(i % #AUTO_OPTIONS) + 1]
    end
  end
  return 0
end

-- ── scan state ───────────────────────────────────────────────────────────────

local results           = {}
local gpsX, gpsY, gpsZ = nil, nil, nil
local scanMsg           = "Press R to scan"

local function doScan()
  -- Check cooldown first; if busy just update message and bail out.
  -- The auto-timer (or manual R press) will retry.
  if scanner.nextScan then
    local ok, remaining = pcall(scanner.nextScan)
    if ok and type(remaining) == "number" and remaining > 0 then
      scanMsg = ("cooldown: %.0fs"):format(remaining)
      return false
    end
  end

  gpsX, gpsY, gpsZ = gps.locate(2)

  local ok, data = pcall(scanner.scan, SCAN_RADIUS)
  if not ok or type(data) ~= "table" then
    local errStr = tostring(data)
    if errStr:find("radius") or errStr:find("range") or errStr:find("too") then
      scanMsg = "Radius " .. SCAN_RADIUS .. " exceeds server max!"
    else
      scanMsg = "Scan error: " .. errStr:sub(1, 20)
    end
    return false
  end

  results = {}
  local groups = {}

  for _, b in ipairs(data) do
    local spec = isSpecial(b.name)
    if spec or isOre(b.name) then
      local d = dist3(b.x, b.y, b.z)
      local g = groups[b.name]
      if not g then
        groups[b.name] = {
          count = 1, dx = b.x, dy = b.y, dz = b.z, d = d, special = spec,
        }
      else
        g.count = g.count + 1
        if d < g.d then g.dx, g.dy, g.dz, g.d = b.x, b.y, b.z, d end
      end
    end
  end

  for name, g in pairs(groups) do
    results[#results + 1] = {
      name    = name,
      label   = prettyName(name),
      count   = g.count,
      dx      = g.dx, dy = g.dy, dz = g.dz,
      dist    = g.d,
      special = g.special,
    }
  end

  table.sort(results, function(a, b)
    if a.special ~= b.special then return a.special end
    return a.dist < b.dist
  end)

  scanMsg = os.date("scanned %H:%M:%S")
  return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────

local scroll  = 0
local perPage = 1

local function drawScreen()
  term.setBackgroundColor(colors.black)
  term.clear()

  -- Row 1: title + controls
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  term.write("GEO FINDER")
  term.setTextColor(colors.gray)
  term.setCursorPos(12, 1)
  term.write("[R]scan [A]auto [Q]")

  -- Row 2: GPS/scan time (left) + auto status (right)
  local autoStr = autoInterval > 0
    and ("[A:%ds]"):format(autoInterval)
    or  "[A:off]"
  term.setCursorPos(1, 2)
  if gpsX then
    term.setTextColor(colors.cyan)
    local gStr = ("GPS %d %d %d"):format(gpsX, gpsY, gpsZ)
    term.write(gStr:sub(1, W - #autoStr - 1))
  else
    term.setTextColor(colors.gray)
    local tStr = ("GPS:---  %s"):format(scanMsg)
    term.write(tStr:sub(1, W - #autoStr - 1))
  end
  term.setCursorPos(W - #autoStr + 1, 2)
  term.setTextColor(autoInterval > 0 and colors.lime or colors.gray)
  term.write(autoStr)

  -- Row 3: separator + result summary
  term.setCursorPos(1, 3)
  term.setTextColor(colors.gray)
  if #results > 0 then
    local nSpec = 0
    for _, r in ipairs(results) do if r.special then nSpec = nSpec + 1 end end
    local info = (" %d types, %d special, r=%d "):format(#results, nSpec, SCAN_RADIUS)
    if #info > W then info = (" %d/%dspec r=%d "):format(#results, nSpec, SCAN_RADIUS) end
    local pad  = W - #info
    term.write(string.rep("-", math.floor(pad / 2)) .. info
            .. string.rep("-", math.ceil(pad / 2)))
  else
    term.write(string.rep("-", W))
  end

  -- Row 4+: optional extra-terms banner, then ore list
  local bodyStart = 4
  if #extraTerms > 0 and H > 6 then
    term.setCursorPos(1, 4)
    term.setTextColor(colors.orange)
    term.write(("extra: %s"):format(table.concat(extraTerms, ", ")):sub(1, W))
    bodyStart = 5
  end

  local bodyH = H - bodyStart + 1
  perPage = math.floor(bodyH / 2)

  if #results == 0 then
    term.setTextColor(colors.gray)
    term.setCursorPos(2, bodyStart)
    term.write("No ores in range (r=" .. SCAN_RADIUS .. ")")
    return
  end

  local row = bodyStart
  for i = scroll + 1, #results do
    if row + 1 > H then break end
    local r = results[i]

    -- Row A: name + count + distance
    local distStr  = ("%dm"):format(math.floor(r.dist + 0.5))
    local countStr = r.count > 1 and (" x%d"):format(r.count) or ""
    local nameStr  = r.label .. countStr
    local nameMax  = W - #distStr - 1
    if #nameStr > nameMax then nameStr = nameStr:sub(1, nameMax - 1) .. "~" end

    term.setCursorPos(1, row)
    term.setTextColor(r.special and colors.red or colors.white)
    term.write(nameStr)
    term.setTextColor(r.special and colors.orange or colors.gray)
    term.setCursorPos(W - #distStr + 1, row)
    term.write(distStr)

    -- Row B: direction + absolute coords if GPS available
    local dir = dirStr(r.dx, r.dy, r.dz)
    if gpsX then
      local absStr = (" [%d,%d,%d]"):format(gpsX + r.dx, gpsY + r.dy, gpsZ + r.dz)
      if #dir + #absStr <= W - 2 then dir = dir .. absStr end
    end
    term.setCursorPos(3, row + 1)
    term.setTextColor(colors.cyan)
    term.write(dir:sub(1, W - 2))

    row = row + 2
  end

  -- Scroll indicators
  if scroll > 0 then
    term.setTextColor(colors.gray)
    term.setCursorPos(W - 5, bodyStart)
    term.write("[\x1e up]")
  end
  if scroll + perPage < #results then
    term.setTextColor(colors.gray)
    term.setCursorPos(W - 7, H)
    term.write("[\x1f more]")
  end
end

-- ── main ─────────────────────────────────────────────────────────────────────

-- Initial scan splash
term.setBackgroundColor(colors.black)
term.setTextColor(colors.yellow)
term.clear()
term.setCursorPos(1, 1)
term.write("GEO FINDER - Scanning...")
if #extraTerms > 0 then
  term.setCursorPos(1, 2)
  term.setTextColor(colors.cyan)
  term.write("extra: " .. table.concat(extraTerms, ", "))
end
if autoInterval > 0 then
  term.setCursorPos(1, 3)
  term.setTextColor(colors.lime)
  term.write(("auto: every %ds"):format(autoInterval))
end

doScan()
resetAutoTimer()
drawScreen()

-- Event loop: handles key presses and auto-refresh timer
while true do
  local ev, p1 = os.pullEvent()

  if ev == "key" then
    if p1 == keys.q then
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      break

    elseif p1 == keys.r then
      doScan()
      scroll = 0
      resetAutoTimer()   -- restart auto countdown after manual scan
      drawScreen()

    elseif p1 == keys.a then
      autoInterval = nextAutoOption()
      resetAutoTimer()
      drawScreen()

    elseif p1 == keys.down or p1 == keys.s then
      if scroll + perPage < #results then
        scroll = scroll + 1
        drawScreen()
      end

    elseif p1 == keys.up or p1 == keys.w then
      if scroll > 0 then
        scroll = scroll - 1
        drawScreen()
      end
    end

  elseif ev == "timer" and p1 == autoTimer then
    doScan()
    resetAutoTimer()   -- schedule next tick
    drawScreen()
  end
end
