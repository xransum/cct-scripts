-- todos.lua
-- CC:Tweaked: persistent to-do list on an Advanced Monitor with touch support.
-- Multiple instances share and sync their list over rednet automatically.
-- A computer with a wired or wireless modem joins the shared pool; without
-- a modem, or with singleton mode set, it manages its own private list.
--
-- Touch the [shared] / [private] tag on the top-right of the monitor to
-- toggle singleton mode on the fly without restarting the script.
--
-- CLI shortcuts (optional):
--   todos singleton    switch this computer to private mode, then run
--   todos shared       switch this computer back to shared mode, then run
--
-- Touch controls (right click the monitor):
--   Tap [shared]/[private]  -> toggle singleton mode
--   Tap an item line         -> toggle done / not done
--   Tap [X] on a line        -> delete that item
--   Tap ADD ITEM             -> switch to add mode; type on the computer terminal
--   Tap CLEAR ALL            -> clears everything (confirmation if > threshold)

local SAVE_FILE         = "todos.txt"
local CONFIG_FILE       = "todos_config.cfg"
local CONFIRM_THRESHOLD = 5
local SYNC_PROTO        = "todos"

-- ── helpers ─────────────────────────────────────────────────────────────────

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
  local raw = f.readAll()
  f.close()
  local ok, result = pcall(textutils.unserialize, raw)
  if ok and type(result) == "table" then return result end
  saveTable(path, default)
  return default
end

local function wordWrap(text, width)
  local lines = {}
  for word in text:gmatch("%S+") do
    if #lines == 0 then
      lines[1] = word
    elseif #lines[#lines] + 1 + #word <= width then
      lines[#lines] = lines[#lines] .. " " .. word
    else
      lines[#lines + 1] = word
    end
  end
  return lines
end

-- ── config ───────────────────────────────────────────────────────────────────

local config = loadTable(CONFIG_FILE, { singleton = false })

local args = { ... }
if args[1] == "singleton" then
  config.singleton = true
  saveTable(CONFIG_FILE, config)
  print("Switched to private (singleton) mode.")
elseif args[1] == "shared" then
  config.singleton = false
  saveTable(CONFIG_FILE, config)
  print("Switched to shared mode.")
end

-- ── peripherals ──────────────────────────────────────────────────────────────

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Place a monitor touching this computer.")
end

mon.setTextScale(0.5)
local monName = peripheral.getName(mon)   -- used to filter monitor_touch events

local speaker = peripheral.find("speaker")
local modem   = peripheral.find("modem", function(_, m) return m.isWireless() end)

-- syncEnabled is a module-level upvalue so broadcast() and syncLoop() always
-- read the current value after a mode toggle re-initialises it.
local syncEnabled = false

local function playSound(instrument, pitch, volume)
  if speaker and instrument ~= nil then
    pcall(speaker.playNote, instrument, volume or 1, pitch or 12)
  end
end

-- ── todos state ──────────────────────────────────────────────────────────────

local todos = {}

local function loadTodos()
  todos = loadTable(SAVE_FILE, {})
end

local function saveTodos()
  saveTable(SAVE_FILE, todos)
end

local function broadcast()
  if syncEnabled then
    rednet.broadcast(
      { type = "sync", todos = todos, sender = os.getComputerID() },
      SYNC_PROTO
    )
  end
end

-- ── UI state ─────────────────────────────────────────────────────────────────

local itemRows = {}
local addButtonRow, clearButtonRow
local yesButtonRow, noButtonRow, yesButtonCol, noButtonCol
local modeTagX, modeTagLen   -- position of the tappable mode tag on row 1
local helpButtonRow, helpButtonX
local mode            = "list"
local restartRequested = false

-- ── drawing ──────────────────────────────────────────────────────────────────

local function drawList()
  local w, h = mon.getSize()
  itemRows = {}

  -- Title, left-center
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, 1)
  mon.write("TO-DO LIST")

  -- Mode tag only shown when a modem is present (something to actually toggle)
  if modem then
    local tag      = config.singleton and "[private]" or "[shared]"
    local tagColor = config.singleton and colors.orange or colors.lime
    modeTagX   = w - #tag + 1
    modeTagLen = #tag
    mon.setTextColor(tagColor)
    mon.setCursorPos(modeTagX, 1)
    mon.write(tag)
  else
    modeTagX   = w + 1   -- sentinel: tap check will never fire
    modeTagLen = 0
  end

  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  local row        = 3
  local maxItemRow = h - 2

  if #todos == 0 then
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.gray)
    mon.write("Nothing here. Tap ADD below.")
  else
    for i, item in ipairs(todos) do
      if row > maxItemRow then break end
      mon.setCursorPos(2, row)
      if item.done then
        mon.setTextColor(colors.green)
        mon.write(string.format("[x] %s", item.text))
      else
        mon.setTextColor(colors.white)
        mon.write(string.format("[ ] %s", item.text))
      end
      mon.setTextColor(colors.red)
      mon.setCursorPos(w - 3, row)
      mon.write("[X]")
      itemRows[row] = i
      row = row + 1
    end
  end

  mon.setCursorPos(1, h - 1)
  mon.setTextColor(colors.gray)
  mon.write(string.rep("-", w))

  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.setCursorPos(2, h)
  mon.write(" + ADD ITEM ")
  addButtonRow = h

  mon.setCursorPos(w - 14, h)
  mon.write(" CLEAR ALL ")
  clearButtonRow = h

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.cyan)
  helpButtonX   = w - 2
  helpButtonRow = h
  mon.setCursorPos(helpButtonX, h)
  mon.write("[?]")
end

local function drawAddPrompt()
  local w, h = mon.getSize()
  local midH  = math.floor(h / 2)

  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - 8) / 2) + 1, midH - 1)
  mon.write("ADD ITEM")

  mon.setTextColor(colors.white)
  local msg1 = "Open the computer terminal"
  mon.setCursorPos(math.max(1, math.floor((w - #msg1) / 2) + 1), midH + 1)
  mon.write(msg1)

  local msg2 = "and type the new item, then press Enter."
  mon.setCursorPos(math.max(1, math.floor((w - #msg2) / 2) + 1), midH + 2)
  mon.write(msg2)

  mon.setTextColor(colors.gray)
  local msg3 = "(Press Enter with nothing typed to cancel)"
  mon.setCursorPos(math.max(1, math.floor((w - #msg3) / 2) + 1), midH + 4)
  mon.write(msg3)
end

local function drawConfirmClear()
  local w, h = mon.getSize()
  mon.setTextColor(colors.red)
  local msg = "Clear ALL " .. #todos .. " items?"
  mon.setCursorPos(math.floor((w - #msg) / 2) + 1, math.floor(h / 2) - 1)
  mon.write(msg)

  local row = math.floor(h / 2) + 1
  mon.setBackgroundColor(colors.green)
  mon.setTextColor(colors.white)
  yesButtonCol = math.floor(w / 2) - 8
  mon.setCursorPos(yesButtonCol, row)
  mon.write(" YES, CLEAR ")
  yesButtonRow = row

  mon.setBackgroundColor(colors.gray)
  noButtonCol = math.floor(w / 2) + 2
  mon.setCursorPos(noButtonCol, row)
  mon.write("   CANCEL   ")
  noButtonRow = row

  mon.setBackgroundColor(colors.black)
end

local function drawHelp()
  local w, h = mon.getSize()
  local row   = 3

  local function put(text, col)
    for _, line in ipairs(wordWrap(text, w - 2)) do
      if row > h - 2 then return end
      mon.setTextColor(col or colors.white)
      mon.setCursorPos(2, row)
      mon.write(line)
      row = row + 1
    end
  end

  -- Title + close hint
  local title = "HELP"
  local hint  = "[tap:close]"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
  mon.write(title)
  if w >= #title + #hint + 4 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(w - #hint + 1, 1)
    mon.write(hint)
  end

  -- Top separator
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, 2)
  mon.write(string.rep("-", w))

  -- Mode tags (only relevant when a modem is attached)
  put("[shared]",  colors.lime)
  put("Syncs todos with nearby computers via rednet. Requires a modem.", colors.white)
  put("[private]", colors.orange)
  put("Local list only. Sync paused even when modem is present.", colors.white)
  put("No mode tag? No modem — running standalone. All features still work.", colors.gray)

  -- Divider + controls
  if row <= h - 2 then
    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, row)
    mon.write(string.rep("-", w))
    row = row + 1
  end
  put("Tap item: toggle  Tap [X]: delete", colors.white)
  put("ADD ITEM: add  CLEAR ALL: wipe list", colors.white)

  -- Bottom separator + credit
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
  if mode == "list" then
    drawList()
  elseif mode == "add_prompt" then
    drawAddPrompt()
  elseif mode == "confirm_clear" then
    drawConfirmClear()
  elseif mode == "help" then
    drawHelp()
  end
end

-- ── actions ──────────────────────────────────────────────────────────────────

local function promptForNewItem()
  print("")
  write("New item (Enter blank to cancel): ")
  local text = read()
  if text and text ~= "" then
    table.insert(todos, { text = text, done = false })
    saveTodos()
    broadcast()
    playSound("pling", 18, 2)
  else
    playSound("hat", 6, 1)
  end
  mode = "list"
  drawMonitor()
end

local function clearAll()
  todos = {}
  saveTodos()
  broadcast()
  mode = "list"
  drawMonitor()
  playSound("bass", 4, 2)
end

-- ── touch handler ─────────────────────────────────────────────────────────────

local function handleTouch(x, y)
  local w = mon.getSize()

  -- Tap anywhere on the help screen to close it
  if mode == "help" then
    mode = "list"
    drawMonitor()
    return
  end

  if mode == "list" then

    -- [?] help button: bottom-right corner
    if y == helpButtonRow and x >= helpButtonX then
      mode = "help"
      drawMonitor()
      return
    end

    -- Mode tag: toggle singleton on/off (only when a modem is attached)
    if modem and y == 1 and x >= modeTagX and x < modeTagX + modeTagLen then
      config.singleton = not config.singleton
      saveTable(CONFIG_FILE, config)
      restartRequested = true
      playSound("hat", 12, 1)
      return
    end

    if y == addButtonRow and x >= 2 and x <= 13 then
      mode = "add_prompt"
      drawMonitor()
      promptForNewItem()
      return
    end

    if y == clearButtonRow and x >= (w - 14) and x <= (w - 3) then
      if #todos > CONFIRM_THRESHOLD then
        mode = "confirm_clear"
        drawMonitor()
        playSound("bell", 12, 2)
      else
        clearAll()
      end
      return
    end

    local index = itemRows[y]
    if index and todos[index] then
      if x >= (w - 3) and x <= w then
        table.remove(todos, index)
        saveTodos()
        broadcast()
        drawMonitor()
        playSound("bass", 2, 1)
      else
        todos[index].done = not todos[index].done
        saveTodos()
        broadcast()
        drawMonitor()
        if todos[index] and todos[index].done then
          playSound("chime", 18, 1)
        else
          playSound("chime", 6, 1)
        end
      end
    end

  elseif mode == "confirm_clear" then
    if y == yesButtonRow and x >= yesButtonCol and x < yesButtonCol + 12 then
      clearAll()
    elseif y == noButtonRow and x >= noButtonCol and x < noButtonCol + 12 then
      mode = "list"
      drawMonitor()
      playSound("hat", 6, 1)
    end
  end
end

-- ── loops ────────────────────────────────────────────────────────────────────

local function touchLoop()
  while true do
    local _, side, x, y = os.pullEvent("monitor_touch")
    if side ~= monName then -- ignore events from other monitors
    elseif mode == "list" or mode == "confirm_clear" or mode == "help" then
      handleTouch(x, y)
      -- Mode tag tap sets restartRequested and returns from handleTouch;
      -- we catch it here to break out of the parallel cleanly.
      if restartRequested then return end
    end
  end
end

local function syncLoop()
  rednet.broadcast({ type = "hello", sender = os.getComputerID() }, SYNC_PROTO)

  while true do
    local _, msg = rednet.receive(SYNC_PROTO)
    if type(msg) == "table" and msg.sender ~= os.getComputerID() then
      if msg.type == "sync" then
        todos = msg.todos
        saveTodos()
        if mode ~= "add_prompt" then
          drawMonitor()
        end
      elseif msg.type == "hello" then
        rednet.broadcast(
          { type = "sync", todos = todos, sender = os.getComputerID() },
          SYNC_PROTO
        )
      end
    end
  end
end

-- ── startup ──────────────────────────────────────────────────────────────────

loadTodos()

while true do
  restartRequested = false

  -- Open or close the modem to match the current config.
  if modem then
    local modemName = peripheral.getName(modem)
    if config.singleton then
      if rednet.isOpen(modemName) then rednet.close(modemName) end
    else
      if not rednet.isOpen(modemName) then rednet.open(modemName) end
    end
  end

  -- Recompute syncEnabled so broadcast() and syncLoop() see the new value.
  syncEnabled = modem ~= nil and not config.singleton

  drawMonitor()

  term.clear()
  term.setCursorPos(1, 1)
  local modeStr = not modem        and "standalone"
               or (config.singleton and "private"
                                     or  "shared (rednet)")
  print("To-do list — " .. modeStr)
  if syncEnabled then print("Computer ID: " .. os.getComputerID()) end
  print("Monitor: " .. monName
        .. " | Modem: " .. (modem and peripheral.getName(modem) or "NONE")
        .. " | Speaker: " .. (speaker and "ok" or "none"))
  print("Tap the mode tag on the monitor to toggle. Type here to add items.")

  if syncEnabled then
    local ok, err = pcall(parallel.waitForAny, touchLoop, syncLoop)
    if not ok and not restartRequested then
      printError("Sync error: " .. tostring(err))
      print("Restarting in 3 seconds...")
      sleep(3)
      restartRequested = true   -- loop back instead of exiting
    end
  else
    touchLoop()
  end

  -- Only loop back if the user tapped the mode toggle; any other exit is final.
  if not restartRequested then break end

  -- Reload config (was saved by the toggle handler before restartRequested was set).
  config = loadTable(CONFIG_FILE, { singleton = false })
end
