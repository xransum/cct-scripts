-- geo_ore_finder.lua
-- Pocket computer Geo Scanner ore finder.
-- Scans for ores within range, groups by type, and shows the relative
-- direction + distance to the nearest block of each type so you can
-- walk straight to it.  GPS coordinates are shown when GPS is available.
--
-- Usage:
--   geo_ore_finder                          (scan for built-in specials)
--   geo_ore_finder diamond emerald          (also match those substrings)
--
-- Controls:
--   R         rescan
--   Q         quit
--   Up / W    scroll up
--   Down / S  scroll down
--
-- Requirements:
--   Advanced Pocket Computer
--   AP Geo Scanner pocket upgrade

-- ── config ────────────────────────────────────────────────────────────────────

local SCAN_RADIUS = 8   -- higher = more FE per scan

-- Always-searched substrings (case-insensitive, partial match).
-- Matching ores are highlighted red and sorted to the top.
local SPECIAL = {
  "allthemodium",
  "vibranium",
  "unobtainium",
  "ancient_debris",
}

-- Append any command-line args as additional special substrings
local args = { ... }
for _, a in ipairs(args) do
  SPECIAL[#SPECIAL + 1] = a:lower()
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

-- ── scan state ───────────────────────────────────────────────────────────────

local results           = {}   -- sorted list of grouped ore entries
local gpsX, gpsY, gpsZ = nil, nil, nil
local scanMsg           = "Press R to scan"

local function doScan()
  results = {}
  gpsX, gpsY, gpsZ = gps.locate(2)

  -- Respect scanner cooldown if the API exposes it
  if scanner.nextScan then
    local ok, remaining = pcall(scanner.nextScan)
    if ok and type(remaining) == "number" and remaining > 0 then
      term.setTextColor(colors.yellow)
      term.setCursorPos(1, H)
      term.write(("Cooldown: %.1fs%s"):format(remaining, string.rep(" ", 8)))
      sleep(remaining)
    end
  end

  local ok, data = pcall(scanner.scan, SCAN_RADIUS)
  if not ok or type(data) ~= "table" then
    scanMsg = "Scan failed: " .. tostring(data):sub(1, 20)
    return false
  end

  -- Group by block name; keep closest instance per group, sum counts
  local groups = {}
  for _, b in ipairs(data) do
    local spec = isSpecial(b.name)
    if spec or isOre(b.name) then
      local d = dist3(b.x, b.y, b.z)
      local g = groups[b.name]
      if not g then
        groups[b.name] = {
          count   = 1,
          dx = b.x, dy = b.y, dz = b.z,
          d       = d,
          special = spec,
        }
      else
        g.count = g.count + 1
        if d < g.d then
          g.dx, g.dy, g.dz, g.d = b.x, b.y, b.z, d
        end
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

  -- Specials first, then sort by distance within each tier
  table.sort(results, function(a, b)
    if a.special ~= b.special then return a.special end
    return a.dist < b.dist
  end)

  scanMsg = os.date("scanned %H:%M:%S")
  return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────

local scroll  = 0
local perPage = 1   -- recalculated in drawScreen

local function drawScreen()
  term.setBackgroundColor(colors.black)
  term.clear()

  -- Row 1: title + controls
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  term.write("GEO FINDER")
  term.setTextColor(colors.gray)
  term.setCursorPos(12, 1)
  term.write("[R]scan [Q]quit")

  -- Row 2: GPS / last scan time
  term.setCursorPos(1, 2)
  if gpsX then
    term.setTextColor(colors.cyan)
    term.write(("GPS %d %d %d"):format(gpsX, gpsY, gpsZ))
    term.setTextColor(colors.gray)
    local ts = "  " .. scanMsg
    if 10 + #ts <= W then term.write(ts) end
  else
    term.setTextColor(colors.gray)
    term.write(("GPS: ---  %s"):format(scanMsg):sub(1, W))
  end

  -- Row 3: separator + result summary
  term.setCursorPos(1, 3)
  term.setTextColor(colors.gray)
  if #results > 0 then
    local nSpec = 0
    for _, r in ipairs(results) do if r.special then nSpec = nSpec + 1 end end
    local info = (" %d types / %d special | r=%d "):format(#results, nSpec, SCAN_RADIUS)
    if #info > W then info = (" %d/%d spec r=%d "):format(#results, nSpec, SCAN_RADIUS) end
    local pad = W - #info
    local lpad = math.floor(pad / 2)
    local rpad = math.ceil(pad / 2)
    term.write(string.rep("-", lpad) .. info .. string.rep("-", rpad))
  else
    term.write(string.rep("-", W))
  end

  -- Show active extra filters on row 3+1 if args were passed
  local bodyStart = 4
  if #args > 0 and H > 6 then
    term.setCursorPos(1, 4)
    term.setTextColor(colors.orange)
    local fStr = "extra: " .. table.concat(args, ", ")
    term.write(fStr:sub(1, W))
    bodyStart = 5
  end

  -- Body rows
  local bodyH = H - bodyStart + 1
  perPage = math.floor(bodyH / 2)   -- 2 rows per ore type

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

    -- Row A: name + block count + distance (right-aligned)
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

    -- Row B: direction string (+ absolute world coords if GPS available)
    local dir = dirStr(r.dx, r.dy, r.dz)
    if gpsX then
      local absStr = (" [%d,%d,%d]"):format(gpsX + r.dx, gpsY + r.dy, gpsZ + r.dz)
      if #dir + #absStr <= W - 2 then
        dir = dir .. absStr
      end
    end
    term.setCursorPos(3, row + 1)
    term.setTextColor(colors.cyan)
    term.write(dir:sub(1, W - 2))

    row = row + 2
  end

  -- Scroll hint at top of body
  if scroll > 0 then
    term.setTextColor(colors.gray)
    term.setCursorPos(W - 5, bodyStart)
    term.write("[\x1e up]")
  end
  -- Scroll hint at bottom
  if scroll + perPage < #results then
    term.setTextColor(colors.gray)
    term.setCursorPos(W - 7, H)
    term.write("[\x1f more]")
  end
end

-- ── main ─────────────────────────────────────────────────────────────────────

-- Initial scan
term.setBackgroundColor(colors.black)
term.setTextColor(colors.yellow)
term.clear()
term.setCursorPos(1, 1)
term.write("GEO FINDER - Scanning...")
if #args > 0 then
  term.setCursorPos(1, 2)
  term.setTextColor(colors.cyan)
  term.write("Extra: " .. table.concat(args, ", "))
end

doScan()
drawScreen()

while true do
  local _, key = os.pullEvent("key")

  if key == keys.q then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    break

  elseif key == keys.r then
    term.setCursorPos(1, H)
    term.setTextColor(colors.yellow)
    term.write("Scanning" .. string.rep(" ", W - 8))
    doScan()
    scroll = 0
    drawScreen()

  elseif key == keys.down or key == keys.s then
    if scroll + perPage < #results then
      scroll = scroll + 1
      drawScreen()
    end

  elseif key == keys.up or key == keys.w then
    if scroll > 0 then
      scroll = scroll - 1
      drawScreen()
    end
  end
end
