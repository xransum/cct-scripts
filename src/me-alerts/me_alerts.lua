-- me_alerts.lua
-- CC:Tweaked: AE2 item threshold monitor with full touch UI + terminal assist.
-- Requires: Advanced Peripherals ME Bridge, Advanced Monitor, optional Speaker.
--
-- Touch controls (monitor):
--   Main list:   tap [+ ADD] → item picker → number pad → adds alert
--                tap item row → edit menu (change threshold / delete)
--                tap [X] on a row → delete with confirm
--                tap [?] → help overlay
--   Picker:      tap item to select it; [< PREV] / [NEXT >] to page
--                tap [CANCEL] to go back
--   Numpad:      tap digits to build threshold value; [←] to backspace; [OK] to confirm
--                tap [CANCEL] to go back
--   Edit menu:   [CHANGE THRESHOLD] | [DELETE ITEM] | [CANCEL]
--   Confirm del: tap [YES, DELETE] or [CANCEL]
--
-- Terminal commands (while script is running):
--   help                  show this list
--   list                  print current watchlist
--   add [name] [thresh]   add item (prompts with Tab-completion if args omitted)
--   remove <n>            remove item n from watchlist
--   enable  <n>           re-enable alerting for item n
--   disable <n>           mute alerting for item n
--   threshold <n> <val>   change min threshold for item n
--
-- Alert behaviour:
--   An item alerts when its count in the ME network drops below its threshold.
--   The alerting rows blink red/dark and the speaker plays a bell sound.
--   Sound repeats every ALERT_SOUND_INTERVAL seconds while still alerting.

local SAVE_FILE            = "me_alerts.cfg"
local POLL_INTERVAL        = 10    -- seconds between ME Bridge polls
local BLINK_RATE           = 0.5   -- seconds per blink phase toggle
local ALERT_SOUND_INTERVAL = 30    -- seconds between repeated alert beeps

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

local function fmtCount(n)
  n = n or 0
  if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
  return tostring(math.floor(n))
end

local function fmtRate(r)
  if math.abs(r) < 0.5 then return "~0/m" end
  local sign = r >= 0 and "+" or "-"
  local abs  = math.abs(r)
  if abs >= 1000 then return sign .. ("%.0fK/m"):format(abs / 1000) end
  return sign .. ("%.0f/m"):format(abs)
end

local function truncate(str, maxLen)
  if #str <= maxLen then return str end
  return str:sub(1, maxLen - 1) .. ">"
end

-- ── peripheral setup ─────────────────────────────────────────────────────────

local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
if not bridge then
  error("No ME Bridge found. Attach an Advanced Peripherals ME Bridge.")
end

local mon = peripheral.find("monitor")
if not mon then error("No monitor found. Attach an Advanced Monitor.") end

mon.setTextScale(0.5)
local monName = peripheral.getName(mon)

local speaker = peripheral.find("speaker")

local function playSound(inst, vol, pitch)
  if speaker then pcall(speaker.playNote, inst, vol or 1, pitch or 12) end
end

local function playSoundEffect(name, vol, pitch)
  if speaker then pcall(speaker.playSound, name, vol or 1, pitch or 1) end
end

-- ── state ─────────────────────────────────────────────────────────────────────

-- Watchlist: [{name, label, threshold, enabled}]
local watchlist = {}

-- Alert state: keyed by item name
-- {count, rate, alerting, lastSound, prevCount, prevTime}
local alertState = {}

-- Cached item list from last ME poll (for picker + terminal autocomplete)
local cachedItems = {}   -- [{name, label, count}]

-- ── UI state ──────────────────────────────────────────────────────────────────

-- mode controls which screen is drawn and how touch events are handled
local mode = "list"
-- "list" | "picker" | "numpad" | "edit_menu" | "confirm_del" | "confirm_clear" | "help"

-- Picker
local pickerPage   = 1
local pickerFilter = ""   -- lowercase search term; "" = show all

-- Numpad
local numpadStr     = ""      -- digits typed so far
local numpadContext = nil     -- "add" | "edit"
local pendingItem   = nil     -- {name, label} when context == "add"
local editIndex     = nil     -- watchlist index when context == "edit"

-- Edit menu / confirm delete
local editMenuIndex    = nil
local confirmDelIndex  = nil

-- Blink
local blinkPhase  = false
local anyAlerting = false

-- Row hit-detection tables (repopulated on each draw)
local itemRows      = {}   -- [row] = watchlist index
local pickerRowMap  = {}   -- [row] = item object (from filtered list)
local pickerClearFilterRow = nil   -- row of [X] clear-filter button (nil when no filter)
local pickerClearFilterX   = nil   -- starting col of [X] button
local addButtonRow, clearButtonRow
local prevPageRow, nextPageRow, pickerCancelRow
local pickerTotalPages = 1   -- saved by drawPicker so touch handler uses correct value
local numpadGrid    = {}   -- [row][col] = button value string
local numpadStartRow, numpadCancelRow
local editRows      = {}   -- [row] = "threshold"|"delete"|"cancel"
local yesDelRow, noDelRow
local yesClearRow, noClearRow
local helpButtonRow, helpButtonX

-- ── watchlist save/load ───────────────────────────────────────────────────────

local function saveWatchlist()
  saveTable(SAVE_FILE, watchlist)
end

local function loadWatchlist()
  watchlist = loadTable(SAVE_FILE, {})
end

-- ── ME network item cache ─────────────────────────────────────────────────────

local function refreshCache()
  local raw = safeCall(bridge.listItems)
           or safeCall(bridge.getItems)
           or safeCall(bridge.items)
  if not raw then cachedItems = {}; return end

  -- Aggregate by item.name (mod:id) so that NBT variants of the same item
  -- (enchanted tools, items with custom data, etc.) collapse into one row
  -- with their counts summed.
  local byName = {}
  for _, item in ipairs(raw) do
    local name  = item.name  or item.id or ""
    local label = item.displayName or item.label or name
    local count = item.amount or item.count or item.qty or 0
    if name ~= "" then
      if byName[name] then
        byName[name].count = byName[name].count + count
      else
        byName[name] = { name = name, label = label, count = count }
      end
    end
  end

  -- Build sorted array, skipping items already on the watchlist
  local inWatchlist = {}
  for _, w in ipairs(watchlist) do inWatchlist[w.name] = true end

  cachedItems = {}
  for _, item in pairs(byName) do
    if not inWatchlist[item.name] then
      cachedItems[#cachedItems + 1] = item
    end
  end
  table.sort(cachedItems, function(a, b)
    return a.label:lower() < b.label:lower()
  end)
end

local function getItemCount(name)
  local result = safeCall(bridge.getItem, { name = name })
  if not result then return 0 end
  return result.amount or result.count or result.qty or 0
end

-- ── drawing ───────────────────────────────────────────────────────────────────

local function drawList()
  local w, h = mon.getSize()
  itemRows = {}

  -- Title
  mon.setTextColor(colors.yellow)
  local title = "ME ALERTS"
  mon.setCursorPos(1, 1)
  mon.write(title)

  -- Help button
  helpButtonX   = w - 2
  helpButtonRow = 1
  mon.setTextColor(colors.cyan)
  mon.setCursorPos(helpButtonX, 1)
  mon.write("[?]")

  -- Separator
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  -- Item rows
  -- Columns: status(1) + space(1) + label(var) + space(1) + count(6) + space(1) + thresh(6) + space(1) + delete(3)
  -- delete [X] is always at columns w-2 .. w
  local delWidth  = 3
  local countW    = 6
  local threshW   = 6
  local fixedEnd  = 1 + 1 + countW + 1 + threshW + 1 + delWidth  -- from right
  local labelMax  = math.max(5, w - 1 - 1 - countW - 1 - threshW - 1 - delWidth - 1)
  local row       = 3
  local maxRow    = h - 2

  if #watchlist == 0 then
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.gray)
    mon.write("No alerts set. Tap ADD below.")
  else
    for i, item in ipairs(watchlist) do
      if row > maxRow then break end
      local state    = alertState[item.name] or {}
      local count    = state.count    or 0
      local alerting = item.enabled and (state.alerting or false)
      local rate     = state.rate     or 0

      -- Status indicator (blinking when alerting)
      if not item.enabled then
        mon.setTextColor(colors.gray)
        mon.setCursorPos(1, row)
        mon.write("-")
      elseif alerting then
        mon.setTextColor(blinkPhase and colors.red or colors.orange)
        mon.setCursorPos(1, row)
        mon.write("!")
      else
        mon.setTextColor(colors.green)
        mon.setCursorPos(1, row)
        mon.write(string.char(0xE2, 0x9C, 0x93) ~= "" and "\x04" or "v")
        -- CC char 0x04 is a small filled diamond; use checkmark char if available
        -- Fallback handled below
        mon.setCursorPos(1, row)
        mon.write("+")
      end

      -- Label
      mon.setTextColor(alerting and (blinkPhase and colors.red or colors.orange) or colors.white)
      mon.setCursorPos(3, row)
      mon.write(truncate(item.label, labelMax))

      -- Count (right-side section, fixed layout)
      local countStr  = fmtCount(count)
      local threshStr = ">" .. fmtCount(item.threshold)

      local secStart = w - delWidth - threshW - 1 - countW
      mon.setTextColor(alerting and (blinkPhase and colors.red or colors.orange) or colors.white)
      mon.setCursorPos(secStart, row)
      mon.write(string.rep(" ", countW - #countStr) .. countStr)

      mon.setTextColor(colors.gray)
      mon.setCursorPos(secStart + countW + 1, row)
      mon.write(string.rep(" ", threshW - #threshStr) .. threshStr)

      -- Delete button
      mon.setTextColor(colors.red)
      mon.setCursorPos(w - 2, row)
      mon.write("[X]")

      itemRows[row] = i
      row = row + 1
    end
  end

  -- Bottom separator + buttons
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, h - 1)
  mon.write(string.rep("-", w))

  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.setCursorPos(2, h)
  mon.write(" + ADD ")
  addButtonRow = h

  -- Search hint centered between ADD and CLEAR ALL (show when gap is wide enough)
  local gapStart = 10    -- first col after ADD button + 1 space
  local gapEnd   = w - 13  -- last col before CLEAR ALL + 1 space
  local gapW     = gapEnd - gapStart + 1
  local hint     = "search: terminal"
  local shortHint = "search?"
  if gapW >= #hint then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.setCursorPos(gapStart + math.floor((gapW - #hint) / 2), h)
    mon.write(hint)
  elseif gapW >= #shortHint then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.setCursorPos(gapStart + math.floor((gapW - #shortHint) / 2), h)
    mon.write(shortHint)
  end

  mon.setCursorPos(w - 11, h)
  mon.setBackgroundColor(colors.gray)
  mon.write(" CLEAR ALL ")
  clearButtonRow = h

  mon.setBackgroundColor(colors.black)
end

local function drawPicker()
  local w, h = mon.getSize()
  pickerRowMap           = {}
  pickerClearFilterRow   = nil
  pickerClearFilterX     = nil

  -- Apply search filter
  local filtered = {}
  if pickerFilter == "" then
    filtered = cachedItems
  else
    for _, item in ipairs(cachedItems) do
      if item.label:lower():find(pickerFilter, 1, true) then
        filtered[#filtered + 1] = item
      end
    end
  end

  -- itemStart depends on whether the hint banner occupies row 3
  local itemStart = (pickerFilter == "") and 4 or 3

  -- pageSize: rows itemStart..h-2, minus 1 to leave a small scroll buffer
  local pageSize = math.max(1, h - 2 - itemStart)

  local totalPages = math.max(1, math.ceil(#filtered / pageSize))
  pickerTotalPages = totalPages   -- save for touch handler
  if pickerPage > totalPages then pickerPage = totalPages end
  if pickerPage < 1          then pickerPage = 1          end

  local startIdx = (pickerPage - 1) * pageSize + 1

  -- Title + filter indicator + [X] clear button
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, 1)
  mon.write("SELECT ITEM")
  local pgStr = ("pg %d/%d"):format(pickerPage, totalPages)
  if pickerFilter ~= "" then
    -- Layout row 1: SELECT ITEM  "filter" [X]  pg N/M
    -- [X] sits between filter text and pgStr with one-space gaps on each side
    local clearX   = w - #pgStr - 1 - 3   -- [X] is 3 chars; 1 space gap before pgStr
    local filterX  = 13
    local filterMax = math.max(0, clearX - filterX - 1)  -- 1 space gap before [X]
    if filterMax > 0 then
      mon.setTextColor(colors.orange)
      mon.setCursorPos(filterX, 1)
      mon.write(truncate('"' .. pickerFilter .. '"', filterMax))
    end
    -- [X] button on orange background
    mon.setBackgroundColor(colors.orange)
    mon.setTextColor(colors.black)
    mon.setCursorPos(clearX, 1)
    mon.write("[X]")
    mon.setBackgroundColor(colors.black)
    pickerClearFilterRow = 1
    pickerClearFilterX   = clearX
  end
  mon.setTextColor(colors.gray)
  mon.setCursorPos(w - #pgStr + 1, 1)
  mon.write(pgStr)

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  -- Cyan hint banner on row 3 when no filter is active
  if pickerFilter == "" then
    mon.setBackgroundColor(colors.cyan)
    mon.setTextColor(colors.black)
    mon.setCursorPos(1, 3)
    mon.write(string.rep(" ", w))
    local bannerText  = "terminal: search [keyword]"
    local shortBanner = "search [keyword]"
    local txt = #bannerText <= w and bannerText or shortBanner
    mon.setCursorPos(math.max(1, math.floor((w - #txt) / 2) + 1), 3)
    mon.write(truncate(txt, w))
    mon.setBackgroundColor(colors.black)
  end

  -- Item rows
  if #filtered == 0 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(2, itemStart)
    mon.write(pickerFilter == "" and "No items found." or 'No matches for "' .. pickerFilter .. '".')
  else
    for row = itemStart, h - 2 do
      local idx = startIdx + (row - itemStart)
      if idx > #filtered then break end
      local item     = filtered[idx]
      local countStr = fmtCount(item.count)
      local labelMax = w - #countStr - 2
      mon.setTextColor(colors.white)
      mon.setCursorPos(2, row)
      mon.write(truncate(item.label, labelMax))
      mon.setTextColor(colors.gray)
      mon.setCursorPos(w - #countStr + 1, row)
      mon.write(countStr)
      pickerRowMap[row] = filtered[idx]   -- store item directly, not index
    end
  end

  -- Footer
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, h - 1)
  mon.write(string.rep("-", w))

  local prevText   = "< PREV"
  local nextText   = "NEXT >"
  local cancelText = "CANCEL"

  mon.setBackgroundColor(pickerPage > 1 and colors.gray or colors.black)
  mon.setTextColor(colors.white)
  mon.setCursorPos(2, h)
  mon.write(prevText)
  prevPageRow = h

  mon.setBackgroundColor(pickerPage < totalPages and colors.gray or colors.black)
  mon.setCursorPos(w - #nextText - 1, h)
  mon.write(nextText)
  nextPageRow = h

  mon.setBackgroundColor(colors.red)
  mon.setTextColor(colors.white)
  local cancelX = math.floor((w - #cancelText) / 2) + 1
  mon.setCursorPos(cancelX, h)
  mon.write(cancelText)
  pickerCancelRow = h

  mon.setBackgroundColor(colors.black)
end

local function drawNumpad()
  local w, h = mon.getSize()
  numpadGrid = {}

  local title = numpadContext == "edit"
    and ("EDIT: " .. (watchlist[editIndex] and watchlist[editIndex].label or "?"))
    or  ("ADD:  " .. (pendingItem and pendingItem.label or "?"))

  -- Title
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, 1)
  mon.write(truncate(title, w))

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  -- Value display
  local valLabel = "Min threshold:"
  local valDisp  = numpadStr == "" and "_" or numpadStr
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 3)
  mon.write(valLabel)
  mon.setTextColor(colors.white)
  mon.setCursorPos(#valLabel + 2, 3)
  mon.write(valDisp)

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 4)
  mon.write(string.rep("-", w))

  -- Button grid: 3 columns, rows 5+
  -- Layout: [7][8][9] / [4][5][6] / [1][2][3] / [←][0][OK]
  local btnW    = 4   -- each button: "[X]" = 3 chars + 1 space
  local gridW   = btnW * 3 - 1   -- 3 buttons, 2 gaps
  local gridX   = math.max(1, math.floor((w - gridW) / 2) + 1)
  numpadStartRow = 5

  local layout = {
    { "7", "8", "9" },
    { "4", "5", "6" },
    { "1", "2", "3" },
    { "DEL", "0", "OK" },
  }

  for ri, rowBtns in ipairs(layout) do
    local screenRow = numpadStartRow + ri - 1
    if screenRow > h - 1 then break end
    numpadGrid[screenRow] = {}
    for ci, val in ipairs(rowBtns) do
      local x = gridX + (ci - 1) * btnW
      local label = val == "DEL" and "[<]" or (val == "OK" and "[v]" or ("[" .. val .. "]"))
      local bg = val == "OK"  and colors.green
              or val == "DEL" and colors.orange
              or colors.gray
      mon.setBackgroundColor(bg)
      mon.setTextColor(colors.white)
      mon.setCursorPos(x, screenRow)
      mon.write(label)
      numpadGrid[screenRow][x] = val
      -- Store each x in the column range
      for dx = 0, #label - 1 do
        numpadGrid[screenRow][x + dx] = val
      end
    end
    mon.setBackgroundColor(colors.black)
  end

  -- Cancel button
  numpadCancelRow = numpadStartRow + #layout
  if numpadCancelRow <= h then
    local cancelText = "[ CANCEL ]"
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.setCursorPos(math.max(1, math.floor((w - #cancelText) / 2) + 1), numpadCancelRow)
    mon.write(cancelText)
    mon.setBackgroundColor(colors.black)
  end
end

local function drawEditMenu()
  local w, h = mon.getSize()
  editRows = {}

  local item = watchlist[editMenuIndex]
  if not item then mode = "list"; return end

  local midH = math.floor(h / 2)

  mon.setTextColor(colors.yellow)
  local title = "EDIT ITEM"
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, midH - 3)
  mon.write(title)

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, midH - 2)
  mon.write(string.rep("-", w))

  mon.setTextColor(colors.white)
  local ln = truncate(item.label, w)
  mon.setCursorPos(math.floor((w - #ln) / 2) + 1, midH - 1)
  mon.write(ln)

  local st = "Stock: " .. fmtCount((alertState[item.name] or {}).count or 0)
        .. "   Threshold: " .. fmtCount(item.threshold)
  mon.setTextColor(colors.gray)
  mon.setCursorPos(math.max(1, math.floor((w - #st) / 2) + 1), midH)
  mon.write(truncate(st, w))

  mon.setCursorPos(1, midH + 1)
  mon.write(string.rep("-", w))

  local function menuBtn(row, text, bg)
    if row > h then return end
    mon.setBackgroundColor(bg)
    mon.setTextColor(colors.white)
    mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), row)
    mon.write(text)
    mon.setBackgroundColor(colors.black)
    editRows[row] = text
  end

  menuBtn(midH + 2, "[ CHANGE THRESHOLD ]", colors.gray)
  menuBtn(midH + 3, item.enabled and "[  DISABLE ALERT  ]" or "[   ENABLE ALERT  ]", colors.gray)
  menuBtn(midH + 4, "[   DELETE ITEM   ]",  colors.red)
  menuBtn(midH + 5, "[     CANCEL      ]",  colors.black)
end

local function drawConfirmDel()
  local w, h = mon.getSize()
  local item  = watchlist[confirmDelIndex]
  if not item then mode = "list"; return end

  local midH = math.floor(h / 2)

  mon.setTextColor(colors.red)
  local msg = "Delete alert for:"
  mon.setCursorPos(math.floor((w - #msg) / 2) + 1, midH - 2)
  mon.write(msg)

  mon.setTextColor(colors.white)
  local ln = truncate(item.label, w)
  mon.setCursorPos(math.floor((w - #ln) / 2) + 1, midH - 1)
  mon.write(ln)

  local yesText = "[ YES, DELETE ]"
  mon.setBackgroundColor(colors.red)
  mon.setTextColor(colors.white)
  yesDelRow = midH + 1
  mon.setCursorPos(math.max(1, math.floor((w - #yesText) / 2) + 1), yesDelRow)
  mon.write(yesText)

  local noText = "[   CANCEL    ]"
  mon.setBackgroundColor(colors.gray)
  noDelRow = midH + 2
  mon.setCursorPos(math.max(1, math.floor((w - #noText) / 2) + 1), noDelRow)
  mon.write(noText)

  mon.setBackgroundColor(colors.black)
end

local function drawConfirmClearAll()
  local w, h = mon.getSize()
  local midH = math.floor(h / 2)
  local count = #watchlist

  mon.setTextColor(colors.red)
  local msg = "Clear ALL alerts?"
  mon.setCursorPos(math.floor((w - #msg) / 2) + 1, midH - 2)
  mon.write(msg)

  mon.setTextColor(colors.gray)
  local sub = ("(" .. count .. " item" .. (count == 1 and "" or "s") .. ")")
  mon.setCursorPos(math.floor((w - #sub) / 2) + 1, midH - 1)
  mon.write(sub)

  local yesText = "[ YES, CLEAR ALL ]"
  mon.setBackgroundColor(colors.red)
  mon.setTextColor(colors.white)
  yesClearRow = midH + 1
  mon.setCursorPos(math.max(1, math.floor((w - #yesText) / 2) + 1), yesClearRow)
  mon.write(yesText)

  local noText = "[    CANCEL     ]"
  mon.setBackgroundColor(colors.gray)
  noClearRow = midH + 2
  mon.setCursorPos(math.max(1, math.floor((w - #noText) / 2) + 1), noClearRow)
  mon.write(noText)

  mon.setBackgroundColor(colors.black)
end

local function drawHelp()
  local w, h = mon.getSize()
  local row   = 3

  local function put(text, col)
    for _, line in ipairs((function()
      local lines = {}
      for word in text:gmatch("%S+") do
        if #lines == 0 then lines[1] = word
        elseif #lines[#lines] + 1 + #word <= w - 2 then
          lines[#lines] = lines[#lines] .. " " .. word
        else lines[#lines + 1] = word end
      end
      return lines
    end)()) do
      if row > h - 2 then return end
      mon.setTextColor(col or colors.white)
      mon.setCursorPos(2, row)
      mon.write(line)
      row = row + 1
    end
  end

  local title = "HELP"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
  mon.write(title)

  local hint = "[tap: close]"
  if w >= #title + #hint + 4 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(w - #hint + 1, 1)
    mon.write(hint)
  end

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  put("! = alerting (stock below threshold)  + = OK  - = disabled", colors.white)
  put("Tap item row to edit threshold, enable/disable, or delete.", colors.gray)
  put("Tap [X] on a row to delete.", colors.gray)
  put("ADD pulls the live item list from your ME network.", colors.gray)

  mon.setTextColor(colors.gray)
  if row <= h - 1 then
    mon.setCursorPos(1, row); mon.write(string.rep("-", w)); row = row + 1
  end

  put("Terminal: add / remove / enable / disable / threshold", colors.white)
  put("Type 'help' on the terminal for full command list.", colors.gray)

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, h - 1)
  mon.write(string.rep("-", w))
  local credit = "-- github.com/xransum"
  mon.setTextColor(colors.cyan)
  mon.setCursorPos(math.max(1, math.floor((w - #credit) / 2) + 1), h)
  mon.write(credit)
end

local function drawMonitor()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  if     mode == "list"          then drawList()
  elseif mode == "picker"        then drawPicker()
  elseif mode == "numpad"        then drawNumpad()
  elseif mode == "edit_menu"     then drawEditMenu()
  elseif mode == "confirm_del"   then drawConfirmDel()
  elseif mode == "confirm_clear" then drawConfirmClearAll()
  elseif mode == "help"          then drawHelp()
  end
end

-- ── actions ───────────────────────────────────────────────────────────────────

local function commitWatchlistChange()
  saveWatchlist()
  mode = "list"
  drawMonitor()
end

local function addAlert(name, label, threshold)
  -- Prevent duplicates
  for _, w in ipairs(watchlist) do
    if w.name == name then return false, "already in watchlist" end
  end
  watchlist[#watchlist + 1] = {
    name      = name,
    label     = label or name,
    threshold = threshold,
    enabled   = true,
  }
  commitWatchlistChange()
  return true
end

local function removeAlert(idx)
  if not watchlist[idx] then return false end
  table.remove(watchlist, idx)
  alertState[watchlist[idx] and watchlist[idx].name or ""] = nil
  commitWatchlistChange()
  return true
end

local function setThreshold(idx, val)
  if not watchlist[idx] then return false end
  watchlist[idx].threshold = val
  commitWatchlistChange()
  return true
end

local function setEnabled(idx, en)
  if not watchlist[idx] then return false end
  watchlist[idx].enabled = en
  commitWatchlistChange()
  return true
end

-- ── touch handler ─────────────────────────────────────────────────────────────

local function handleTouch(x, y)
  local w = mon.getSize()

  if mode == "help" then
    mode = "list"; drawMonitor(); return
  end

  if mode == "list" then
    -- Help button
    if y == helpButtonRow and x >= helpButtonX then
      mode = "help"; drawMonitor(); return
    end

    -- ADD button
    if y == addButtonRow and x >= 2 and x <= 8 then
      refreshCache()
      pickerPage = 1
      mode = "picker"
      drawMonitor()
      return
    end

    -- CLEAR ALL → confirm screen
    if y == clearButtonRow and x >= (w - 11) then
      if #watchlist > 0 then
        mode = "confirm_clear"
        drawMonitor()
      end
      return
    end

    -- Item row: toggle done or delete
    local idx = itemRows[y]
    if idx and watchlist[idx] then
      if x >= (w - 2) and x <= w then
        -- [X] delete
        confirmDelIndex = idx
        mode = "confirm_del"
        drawMonitor()
        playSound("hat", 1, 12)
      else
        -- Tap row → edit menu
        editMenuIndex = idx
        mode = "edit_menu"
        drawMonitor()
      end
    end
    return
  end

  if mode == "picker" then
    -- [X] clear-filter button (row 1, only when filter active)
    if pickerClearFilterRow and y == pickerClearFilterRow
       and pickerClearFilterX and x >= pickerClearFilterX and x <= pickerClearFilterX + 2 then
      pickerFilter = ""
      pickerPage   = 1
      drawMonitor()
      return
    end
    -- All three footer buttons share the same bottom row (h).
    -- Distinguish them by x position: PREV is left, NEXT is right, CANCEL is centre.
    if y == prevPageRow then
      local prevText = "< PREV"
      local nextText = "NEXT >"
      if x >= 2 and x <= 2 + #prevText - 1 then
        -- PREV
        if pickerPage > 1 then pickerPage = pickerPage - 1; drawMonitor() end
      elseif x >= w - #nextText then
        -- NEXT
        if pickerPage < pickerTotalPages then pickerPage = pickerPage + 1; drawMonitor() end
      else
        -- CANCEL (middle of the row)
        mode = "list"; drawMonitor()
      end
      return
    end
    local item = pickerRowMap[y]   -- item stored directly in map
    if item then
      -- Already filtered out watchlist dupes in refreshCache, but guard anyway
      local dup = false
      for _, wl in ipairs(watchlist) do
        if wl.name == item.name then dup = true; break end
      end
      if dup then return end
      pendingItem = { name = item.name, label = item.label }
      numpadStr     = ""
      numpadContext = "add"
      mode = "numpad"
      drawMonitor()
      playSound("hat", 1, 18)
    end
    return
  end

  if mode == "numpad" then
    -- Cancel
    if y == numpadCancelRow then
      numpadStr = ""
      mode = numpadContext == "edit" and "edit_menu" or "list"
      drawMonitor()
      return
    end
    -- Digit / DEL / OK buttons
    local row_btns = numpadGrid[y]
    if row_btns then
      local val = row_btns[x]
      if val then
        if val == "DEL" then
          numpadStr = numpadStr:sub(1, -2)
          drawMonitor()
          playSound("hat", 1, 6)
        elseif val == "OK" then
          local num = tonumber(numpadStr)
          if num and num >= 0 then
            if numpadContext == "add" and pendingItem then
              addAlert(pendingItem.name, pendingItem.label, num)
              playSound("pling", 2, 18)
            elseif numpadContext == "edit" and editIndex then
              setThreshold(editIndex, num)
              playSound("pling", 2, 18)
            end
            numpadStr = ""
          else
            playSound("bass", 1, 4)
          end
        else
          if #numpadStr < 10 then
            numpadStr = numpadStr .. val
            drawMonitor()
            playSound("hat", 1, 12)
          end
        end
      end
    end
    return
  end

  if mode == "edit_menu" then
    local action = editRows[y]
    if not action then return end
    if action:find("CHANGE THRESHOLD") then
      numpadStr     = tostring(watchlist[editMenuIndex].threshold)
      numpadContext = "edit"
      editIndex     = editMenuIndex
      mode = "numpad"
      drawMonitor()
    elseif action:find("DISABLE") or action:find("ENABLE") then
      setEnabled(editMenuIndex, not watchlist[editMenuIndex].enabled)
      playSound("hat", 1, 12)
    elseif action:find("DELETE") then
      confirmDelIndex = editMenuIndex
      mode = "confirm_del"
      drawMonitor()
    elseif action:find("CANCEL") then
      mode = "list"; drawMonitor()
    end
    return
  end

  if mode == "confirm_del" then
    if y == yesDelRow then
      local name = watchlist[confirmDelIndex] and watchlist[confirmDelIndex].name
      table.remove(watchlist, confirmDelIndex)
      if name then alertState[name] = nil end
      saveWatchlist()
      mode = "list"
      drawMonitor()
      playSound("bass", 2, 4)
    elseif y == noDelRow then
      mode = "list"; drawMonitor()
      playSound("hat", 1, 6)
    end
    return
  end

  if mode == "confirm_clear" then
    if y == yesClearRow then
      watchlist  = {}
      alertState = {}
      saveWatchlist()
      mode = "list"
      drawMonitor()
      playSound("bass", 2, 4)
    elseif y == noClearRow then
      mode = "list"; drawMonitor()
      playSound("hat", 1, 6)
    end
    return
  end
end

-- ── terminal interface ────────────────────────────────────────────────────────

local function termPrintHelp()
  print("me-alerts terminal commands:")
  print("  list                   show watchlist")
  print("  add [name] [thresh]    add item alert")
  print("  remove <n>             remove item n")
  print("  enable  <n>            enable alert for item n")
  print("  disable <n>            disable alert for item n")
  print("  threshold <n> <val>    change threshold for item n")
  print("  search [term]          filter picker by name (no arg clears)")
end

local function termPrintList()
  if #watchlist == 0 then print("Watchlist is empty."); return end
  for i, item in ipairs(watchlist) do
    local state = alertState[item.name] or {}
    local status = not item.enabled and "off"
               or (state.alerting and "ALERT") or "ok"
    print(("[%d] %s | threshold: %d | stock: %s | %s"):format(
      i, item.label, item.threshold, fmtCount(state.count or 0), status))
  end
end

local function termAdd(nameArg, threshArg)
  local name
  if nameArg then
    name = nameArg
  else
    -- Build autocomplete list from cache
    local names = {}
    for _, item in ipairs(cachedItems) do names[#names + 1] = item.name end
    table.sort(names)
    write("Item name (Tab completes): ")
    name = read(nil, nil, function(partial)
      local matches = {}
      for _, n in ipairs(names) do
        if n:sub(1, #partial) == partial then
          matches[#matches + 1] = n:sub(#partial + 1)
        end
      end
      return matches
    end)
    if not name or name == "" then print("Cancelled."); return end
  end

  -- Check duplicate
  for i, wl in ipairs(watchlist) do
    if wl.name == name then
      print(("Already in watchlist at position %d."):format(i)); return
    end
  end

  local threshold
  if threshArg then
    threshold = tonumber(threshArg)
  else
    write("Min threshold: ")
    threshold = tonumber(read())
  end
  if not threshold or threshold < 0 then print("Invalid threshold."); return end

  -- Find label from cache or derive from name
  local label = name
  for _, item in ipairs(cachedItems) do
    if item.name == name then label = item.label; break end
  end

  local ok, err = addAlert(name, label, threshold)
  if ok then
    print(("Added: %s  threshold: %d"):format(label, threshold))
    playSound("pling", 2, 18)
  else
    print("Failed: " .. tostring(err))
  end
end

local function termRemove(idx)
  if not idx or not watchlist[idx] then
    print("Usage: remove <n>  (see 'list' for numbers)"); return
  end
  local name = watchlist[idx].name
  local label = watchlist[idx].label
  table.remove(watchlist, idx)
  alertState[name] = nil
  saveWatchlist()
  mode = "list"; drawMonitor()
  print(("Removed: %s"):format(label))
end

local function termEnable(idx, en)
  if not idx or not watchlist[idx] then
    print("Usage: enable/disable <n>"); return
  end
  watchlist[idx].enabled = en
  saveWatchlist(); mode = "list"; drawMonitor()
  print(("%s: %s"):format(en and "Enabled" or "Disabled", watchlist[idx].label))
end

local function termThreshold(idx, val)
  if not idx or not val or not watchlist[idx] then
    print("Usage: threshold <n> <value>"); return
  end
  watchlist[idx].threshold = val
  saveWatchlist(); mode = "list"; drawMonitor()
  print(("Threshold for %s set to %d"):format(watchlist[idx].label, val))
end

local function termSearch(term)
  if term then
    pickerFilter = term:lower()
    print(('Picker filter set to "%s".'):format(pickerFilter))
  else
    pickerFilter = ""
    print("Picker filter cleared.")
  end
  pickerPage = 1
  if mode == "picker" then drawMonitor() end
end

local function terminalLoop()
  print("me-alerts: type 'help' for commands, Ctrl+T to stop.")
  while true do
    write("> ")
    local line = read()
    if line and line ~= "" then
      local parts = {}
      for word in line:gmatch("%S+") do parts[#parts + 1] = word end
      local cmd = parts[1]
      if     cmd == "help"      then termPrintHelp()
      elseif cmd == "list"      then termPrintList()
      elseif cmd == "add"       then termAdd(parts[2], parts[3])
      elseif cmd == "remove"    then termRemove(tonumber(parts[2]))
      elseif cmd == "enable"    then termEnable(tonumber(parts[2]), true)
      elseif cmd == "disable"   then termEnable(tonumber(parts[2]), false)
      elseif cmd == "threshold" then termThreshold(tonumber(parts[2]), tonumber(parts[3]))
      elseif cmd == "search"    then termSearch(parts[2])
      else print("Unknown command. Type 'help'.") end
    end
  end
end

-- ── touch loop ────────────────────────────────────────────────────────────────

local function touchLoop()
  while true do
    local _, side, x, y = os.pullEvent("monitor_touch")
    if side == monName then
      handleTouch(x, y)
    end
  end
end

-- ── alert poll + blink loop ───────────────────────────────────────────────────

local function alertLoop()
  local pollTimer  = os.startTimer(0)      -- first poll fires immediately
  local blinkTimer = nil

  while true do
    local ev, id = os.pullEvent("timer")

    if id == pollTimer then
      -- Poll each enabled watchlist item
      local now = os.epoch("utc")
      for _, item in ipairs(watchlist) do
        if item.enabled then
          local count = getItemCount(item.name)
          local state = alertState[item.name] or {}

          -- Rate in items/minute
          local rate = 0
          if state.prevCount ~= nil and state.prevTime ~= nil then
            local elapsed = (now - state.prevTime) / 1000
            if elapsed > 0 then
              rate = (count - state.prevCount) / elapsed * 60
            end
          end

          local wasAlerting = state.alerting
          local isAlerting  = count < item.threshold

          alertState[item.name] = {
            count     = count,
            rate      = rate,
            alerting  = isAlerting,
            prevCount = count,
            prevTime  = now,
            lastSound = state.lastSound,
          }

          -- Sound: play on first alert, then repeat every ALERT_SOUND_INTERVAL
          if isAlerting then
            local lastSnd = state.lastSound or 0
            if not wasAlerting or (now - lastSnd) >= ALERT_SOUND_INTERVAL * 1000 then
              playSoundEffect("immersiveengineering:alert", 3, 1)
              alertState[item.name].lastSound = now
            end
          end
        end
      end

      -- Also refresh cache for picker/terminal autocomplete
      refreshCache()

      -- Determine overall alert state
      local prevAny = anyAlerting
      anyAlerting = false
      for _, item in ipairs(watchlist) do
        if item.enabled and (alertState[item.name] or {}).alerting then
          anyAlerting = true; break
        end
      end

      -- Start blink timer if now alerting and not already blinking
      if anyAlerting and not blinkTimer then
        blinkTimer = os.startTimer(BLINK_RATE)
      end
      -- Clear blink state if nothing alerting
      if not anyAlerting then
        blinkPhase = false
      end

      if mode == "list" then drawMonitor() end

      pollTimer = os.startTimer(POLL_INTERVAL)

    elseif id == blinkTimer then
      if anyAlerting then
        blinkPhase = not blinkPhase
        if mode == "list" then drawMonitor() end
        blinkTimer = os.startTimer(BLINK_RATE)
      else
        blinkPhase = false
        blinkTimer = nil
        if mode == "list" then drawMonitor() end
      end
    end
  end
end

-- ── main ──────────────────────────────────────────────────────────────────────

loadWatchlist()
refreshCache()
drawMonitor()

print("me-alerts running.")
print("Bridge:  " .. peripheral.getName(bridge))
print("Monitor: " .. peripheral.getName(mon))
print("Speaker: " .. (speaker and peripheral.getName(speaker) or "none"))

local ok, err = pcall(parallel.waitForAny, touchLoop, terminalLoop, alertLoop)
if not ok then
  printError("Fatal error: " .. tostring(err))
  print("Restart the script to recover.")
end
