-- todos.lua
-- CC:Tweaked script: persistent to-do list on an Advanced Monitor with touch support.
-- Requires an Advanced Computer and an Advanced Monitor (for color and touch events).
--
-- Touch controls (right click the monitor):
--   Tap an item line     -> toggle done / not done
--   Tap [X] on a line    -> delete that single item
--   Tap ADD ITEM         -> screen switches to a prompt telling you to type on
--                            the computer. Type the text there and press Enter.
--                            Pressing Enter with nothing typed cancels.
--   Tap CLEAR ALL         -> clears every item. If there are more than
--                            CONFIRM_THRESHOLD items, shows a Yes/No
--                            confirmation screen first.

local SAVE_FILE = "todos.txt"
local CONFIRM_THRESHOLD = 5

local mon = peripheral.find("monitor")
if not mon then
    error("No monitor found. Place a monitor touching this computer.")
end

mon.setTextScale(0.5)

-- Speaker is optional. If none is attached, sound calls just do nothing.
local speaker = peripheral.find("speaker")

local function playSound(instrument, pitch, volume)
    if speaker then
        speaker.playNote(instrument, volume or 1, pitch or 12)
    end
end

local todos = {}
local itemRows = {}
local addButtonRow, clearButtonRow
local mode = "list"   -- "list", "add_prompt", "confirm_clear"

local function loadTodos()
    if fs.exists(SAVE_FILE) then
        local f = fs.open(SAVE_FILE, "r")
        local data = f.readAll()
        f.close()
        local ok, result = pcall(textutils.unserialize, data)
        if ok and type(result) == "table" then
            todos = result
        end
    end
end

local function saveTodos()
    local f = fs.open(SAVE_FILE, "w")
    f.write(textutils.serialize(todos))
    f.close()
end

local function drawList()
    local w, h = mon.getSize()
    itemRows = {}

    mon.setTextColor(colors.yellow)
    local title = "TO-DO LIST"
    mon.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    mon.write(title)

    mon.setTextColor(colors.gray)
    mon.setCursorPos(1, 2)
    mon.write(string.rep("-", w))

    local row = 3
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
end

local function drawAddPrompt()
    local w, h = mon.getSize()
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(math.floor((w - 9) / 2) + 1, math.floor(h / 2) - 1)
    mon.write("ADD ITEM")

    mon.setTextColor(colors.white)
    local msg = "Open the computer terminal"
    mon.setCursorPos(math.floor((w - #msg) / 2) + 1, math.floor(h / 2) + 1)
    mon.write(msg)

    local msg2 = "and type the new item, then press Enter."
    mon.setCursorPos(math.max(1, math.floor((w - #msg2) / 2) + 1), math.floor(h / 2) + 2)
    mon.write(msg2)

    mon.setTextColor(colors.gray)
    local msg3 = "(Press Enter with nothing typed to cancel)"
    mon.setCursorPos(math.max(1, math.floor((w - #msg3) / 2) + 1), math.floor(h / 2) + 4)
    mon.write(msg3)
end

local yesButtonRow, noButtonRow, yesButtonCol, noButtonCol

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

local function drawMonitor()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    if mode == "list" then
        drawList()
    elseif mode == "add_prompt" then
        drawAddPrompt()
    elseif mode == "confirm_clear" then
        drawConfirmClear()
    end
end

local function promptForNewItem()
    print("")
    write("New item (Enter blank to cancel): ")
    local text = read()
    if text and text ~= "" then
        table.insert(todos, { text = text, done = false })
        saveTodos()
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
    mode = "list"
    drawMonitor()
    playSound("bass", 4, 2)
end

local function handleTouch(x, y)
    local w = mon.getSize()

    if mode == "list" then
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
                drawMonitor()
                playSound("bass", 2, 1)
            else
                todos[index].done = not todos[index].done
                saveTodos()
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

loadTodos()
drawMonitor()

term.clear()
term.setCursorPos(1, 1)
print("Touch to-do list running.")
print("Tap ADD ITEM on the monitor, then type here when prompted.")

while true do
    local event, side, x, y = os.pullEvent("monitor_touch")
    if mode == "list" or mode == "confirm_clear" then
        handleTouch(x, y)
    end
    -- touches during "add_prompt" mode are ignored since typing happens
    -- on the computer terminal, not the monitor, until Enter is pressed
end