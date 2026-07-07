-- notepad.lua
-- CC:Tweaked: per-topic plaintext notepad on an Advanced Monitor.
-- Touch tabs to switch topics; [+] to create; [X] to delete (with confirmation).
-- [Edit] launches the native CC editor in the terminal for full text editing.
-- Layout is fully adaptive: reads w,h on every draw so any monitor size works.

local NOTES_DIR = "notes"
local MON_SCALE = 0.5

-- ── peripheral ───────────────────────────────────────────────────────────────

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach an Advanced Monitor to this computer.")
end
mon.setTextScale(MON_SCALE)

-- ── helpers ───────────────────────────────────────────────────────────────────

local function wordWrap(text, width)
  if width <= 0 then return { text } end
  local lines = {}
  -- preserve existing newlines
  for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
    if #segment == 0 then
      lines[#lines + 1] = ""
    else
      local remaining = segment
      while #remaining > 0 do
        if #remaining <= width then
          lines[#lines + 1] = remaining
          break
        end
        -- find last space within width
        local cut = width
        for i = width, 1, -1 do
          if remaining:sub(i, i) == " " then cut = i - 1; break end
        end
        lines[#lines + 1] = remaining:sub(1, cut)
        remaining = remaining:sub(cut + 1):gsub("^%s+", "")
      end
    end
  end
  return lines
end

local function readFile(path)
  if not fs.exists(path) then return "" end
  local f = fs.open(path, "r")
  local s = f.readAll()
  f.close()
  return s or ""
end

local function ensureNotesDir()
  if not fs.exists(NOTES_DIR) then fs.makeDir(NOTES_DIR) end
end

local function topicPath(name)
  return NOTES_DIR .. "/" .. name .. ".txt"
end

-- ── state ─────────────────────────────────────────────────────────────────────

local topics        = {}   -- ordered list of topic name strings
local currentTopic  = nil
local scrollOffsets = {}   -- [name] = int line offset
local tabOffset     = 1    -- index of first visible tab (1-based)
local mode          = "list"  -- "list" | "confirm_delete" | "editing" | "add_prompt"

-- ── topic management ──────────────────────────────────────────────────────────

local function loadTopics()
  ensureNotesDir()
  topics = {}
  if fs.exists(NOTES_DIR) then
    local files = fs.list(NOTES_DIR)
    table.sort(files)
    for _, f in ipairs(files) do
      if f:match("%.txt$") then
        local name = f:sub(1, -5)
        topics[#topics + 1] = name
      end
    end
  end
  if #topics == 0 then
    -- create a default topic
    local f = fs.open(topicPath("General"), "w")
    f.write("")
    f.close()
    topics = { "General" }
  end
  if not currentTopic or not (function()
    for _, t in ipairs(topics) do if t == currentTopic then return true end end
  end)() then
    currentTopic = topics[1]
  end
end

local function addTopic(name)
  ensureNotesDir()
  local f = fs.open(topicPath(name), "w")
  f.write("")
  f.close()
  topics[#topics + 1] = name   -- append so new tabs appear on the right
  currentTopic = name
  scrollOffsets[name] = 0
  tabOffset = #topics           -- scroll tab strip to show the new tab
end

local function deleteTopic(name)
  fs.delete(topicPath(name))
  scrollOffsets[name] = nil
  for i, t in ipairs(topics) do
    if t == name then
      table.remove(topics, i)
      -- switch to adjacent topic
      currentTopic = topics[math.min(i, #topics)] or nil
      break
    end
  end
  tabOffset = 1
end

-- ── draw helpers ──────────────────────────────────────────────────────────────

-- Touch hitbox tables rebuilt every draw
local tabHitboxes        = {}  -- { x1, x2, name }
local tabLeftArrowX      = nil
local tabRightArrowX     = nil
local addButtonX         = nil
local delButtonX         = nil
local editButtonX1       = nil
local editButtonX2       = nil
local scrollUpX          = nil
local scrollDownX        = nil
local yesButtonRow       = nil
local noButtonRow        = nil
local contentLineCount   = 0   -- total wrapped lines in current topic (for scroll clamping)

local function clearHitboxes()
  tabHitboxes      = {}
  tabLeftArrowX    = nil
  tabRightArrowX   = nil
  addButtonX       = nil
  delButtonX       = nil
  editButtonX1     = nil
  editButtonX2     = nil
  scrollUpX        = nil
  scrollDownX      = nil
  yesButtonRow     = nil
  noButtonRow      = nil
end

local TAB_ROW    = 3
local SEP_ROWS   = { 2, 4 }  -- recomputed in draw based on height

local function drawSep(w, r)
  mon.setTextColor(colors.gray)
  mon.setCursorPos(1, r)
  mon.write(string.rep("-", w))
end

-- ── main draw ─────────────────────────────────────────────────────────────────

local function drawList()
  local w, h = mon.getSize()
  clearHitboxes()

  -- ── row 1: title + [+] [X] ──────────────────────────────────────────────
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(1, 1)
  mon.write("NOTEPAD")

  -- [X] delete at far right, [+] add just left of it
  delButtonX = w - 2
  addButtonX = w - 5

  mon.setTextColor(colors.red)
  mon.setCursorPos(delButtonX, 1)
  mon.write("[X]")

  mon.setTextColor(colors.lime)
  mon.setCursorPos(addButtonX, 1)
  mon.write("[+]")

  -- ── row 2: separator ────────────────────────────────────────────────────
  drawSep(w, 2)

  -- ── row 3: tab strip ────────────────────────────────────────────────────
  -- Each tab is "[ Name ]"; arrows are "[<]" / "[>]" (3 chars each)
  -- Available width for tabs = w (arrows shown only when needed, overlap edges)
  local arrowW   = 3
  local stripW   = w  -- full width; arrows sit at col 1 and w-2

  -- Measure each tab
  local tabWidths = {}
  for _, t in ipairs(topics) do
    tabWidths[t] = #t + 4  -- "[ " + name + " ]" → but render as "[ X ]"
  end

  -- Determine visible tabs starting from tabOffset
  -- Reserve space for arrows if needed
  local needLeft  = tabOffset > 1
  local leftW     = needLeft and arrowW or 0
  local available = stripW - leftW

  local visibleTabs = {}
  local used        = 0
  local needRight   = false
  for i = tabOffset, #topics do
    local tw = tabWidths[topics[i]]
    if used + tw > available then
      needRight = true
      break
    end
    visibleTabs[#visibleTabs + 1] = topics[i]
    used = used + tw
  end
  -- also recheck if we need right arrow: any tabs beyond visible
  if #visibleTabs < (#topics - tabOffset + 1) then needRight = true end

  -- Recompute available if right arrow needed
  if needRight then
    available = stripW - leftW - arrowW
    visibleTabs = {}
    used = 0
    for i = tabOffset, #topics do
      local tw = tabWidths[topics[i]]
      if used + tw > available then break end
      visibleTabs[#visibleTabs + 1] = topics[i]
      used = used + tw
    end
  end

  mon.setCursorPos(1, TAB_ROW)
  mon.setTextColor(colors.black)
  mon.setBackgroundColor(colors.black)
  mon.write(string.rep(" ", w))
  mon.setBackgroundColor(colors.black)

  local col = 1

  if needLeft then
    tabLeftArrowX = col
    mon.setCursorPos(col, TAB_ROW)
    mon.setTextColor(colors.gray)
    mon.write("[<]")
    col = col + arrowW
  end

  tabHitboxes = {}
  for _, name in ipairs(visibleTabs) do
    local tw = tabWidths[name]
    local isCurrent = (name == currentTopic)
    mon.setCursorPos(col, TAB_ROW)
    if isCurrent then
      mon.setBackgroundColor(colors.gray)
      mon.setTextColor(colors.yellow)
    else
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.gray)
    end
    -- truncate name if somehow still too wide
    local label = "[ " .. name .. " ]"
    mon.write(label:sub(1, tw))
    mon.setBackgroundColor(colors.black)
    tabHitboxes[#tabHitboxes + 1] = { x1 = col, x2 = col + tw - 1, name = name }
    col = col + tw
  end

  if needRight then
    tabRightArrowX = w - arrowW + 1
    mon.setCursorPos(tabRightArrowX, TAB_ROW)
    mon.setTextColor(colors.gray)
    mon.setBackgroundColor(colors.black)
    mon.write("[>]")
  end

  -- ── row 4: separator ────────────────────────────────────────────────────
  local hasSep4 = h >= 7
  local contentStart = hasSep4 and 5 or 4
  if hasSep4 then drawSep(w, 4) end

  -- ── footer rows ─────────────────────────────────────────────────────────
  local footerSepRow = h - 1
  local footerRow    = h
  local hasSepFooter = h >= 8
  if hasSepFooter then drawSep(w, footerSepRow) end

  -- [Edit] button
  local editLabel = "[Edit]"
  editButtonX1 = 2
  editButtonX2 = editButtonX1 + #editLabel - 1
  if currentTopic then
    mon.setCursorPos(editButtonX1, footerRow)
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.write(editLabel)
    mon.setBackgroundColor(colors.black)
  end

  -- ── content area ────────────────────────────────────────────────────────
  local contentEnd  = hasSepFooter and (footerSepRow - 1) or footerRow - 1
  local contentRows = math.max(0, contentEnd - contentStart + 1)

  -- word-wrap current topic content
  local displayLines = {}
  if currentTopic then
    local raw = readFile(topicPath(currentTopic))
    local textW = math.max(1, w - 2)
    for _, line in ipairs(wordWrap(raw, textW)) do
      displayLines[#displayLines + 1] = line
    end
  end
  contentLineCount = #displayLines

  -- clamp scroll
  local maxScroll = math.max(0, contentLineCount - contentRows)
  if not scrollOffsets[currentTopic] then scrollOffsets[currentTopic] = 0 end
  scrollOffsets[currentTopic] = math.min(scrollOffsets[currentTopic], maxScroll)
  local offset = scrollOffsets[currentTopic]

  -- draw content
  for r = 0, contentRows - 1 do
    local lineIdx = offset + r + 1
    local screenRow = contentStart + r
    mon.setCursorPos(2, screenRow)
    mon.setTextColor(colors.white)
    if displayLines[lineIdx] then
      mon.write(displayLines[lineIdx]:sub(1, w - 2))
    else
      mon.write("")
    end
  end

  -- scroll arrows (only when content overflows)
  if contentLineCount > contentRows then
    scrollUpX   = w - 2
    scrollDownX = w

    mon.setCursorPos(scrollUpX, footerRow)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(offset > 0 and colors.white or colors.gray)
    mon.write("[^]")

    -- overwrite scrollDownX area
    scrollDownX = w - 2  -- reuse same x start since we have "[^][v]"
    -- actually lay them out: [^] at w-5, [v] at w-2
    scrollUpX  = w - 5
    scrollDownX = w - 2

    mon.setCursorPos(scrollUpX, footerRow)
    mon.setTextColor(offset > 0 and colors.white or colors.gray)
    mon.write("[^]")

    mon.setCursorPos(scrollDownX, footerRow)
    mon.setTextColor(offset < maxScroll and colors.white or colors.gray)
    mon.write("[v]")
  end

  -- topic name in header if no tab strip (very small monitors)
  if h < 6 and currentTopic then
    mon.setTextColor(colors.cyan)
    local nameStr = " [" .. currentTopic .. "]"
    mon.setCursorPos(math.min(9, w - #nameStr + 1), 1)
    mon.write(nameStr:sub(1, w - 8))
  end
end

local function drawConfirmDelete()
  local w, h = mon.getSize()
  local midH  = math.floor(h / 2)

  mon.setTextColor(colors.red)
  local msg = 'Delete "' .. (currentTopic or "") .. '"?'
  mon.setCursorPos(math.max(1, math.floor((w - #msg) / 2) + 1), midH - 1)
  mon.write(msg:sub(1, w))

  local yesText = "[ YES, DELETE ]"
  mon.setBackgroundColor(colors.red)
  mon.setTextColor(colors.white)
  yesButtonRow = midH + 1
  mon.setCursorPos(math.max(1, math.floor((w - #yesText) / 2) + 1), yesButtonRow)
  mon.write(yesText)

  local noText = "[   CANCEL    ]"
  mon.setBackgroundColor(colors.gray)
  noButtonRow = midH + 2
  mon.setCursorPos(math.max(1, math.floor((w - #noText) / 2) + 1), noButtonRow)
  mon.write(noText)

  mon.setBackgroundColor(colors.black)
end

local function flashMonitor(msg, col)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local midH = math.floor(h / 2)
  mon.setTextColor(col or colors.white)
  mon.setCursorPos(math.max(1, math.floor((w - #msg) / 2) + 1), midH)
  mon.write(msg:sub(1, w))
  sleep(1.5)
end

local function drawEditing()
  local w, h = mon.getSize()
  local midH  = math.floor(h / 2)
  local msg1  = "Editing in terminal..."
  local msg2  = "Press Ctrl: choose Save, then Exit"
  local msg3  = "(do not choose Run)"
  mon.setTextColor(colors.yellow)
  mon.setCursorPos(math.max(1, math.floor((w - #msg1) / 2) + 1), midH - 1)
  mon.write(msg1:sub(1, w))
  mon.setTextColor(colors.white)
  mon.setCursorPos(math.max(1, math.floor((w - #msg2) / 2) + 1), midH + 1)
  mon.write(msg2:sub(1, w))
  mon.setTextColor(colors.gray)
  mon.setCursorPos(math.max(1, math.floor((w - #msg3) / 2) + 1), midH + 2)
  mon.write(msg3:sub(1, w))
end

local function drawAddPrompt()
  local w, h = mon.getSize()
  local midH  = math.floor(h / 2)
  local msg1  = "Adding new topic..."
  local msg2  = "Type the topic name in the terminal"
  local msg3  = "(press Enter to confirm, blank to cancel)"
  mon.setTextColor(colors.lime)
  mon.setCursorPos(math.max(1, math.floor((w - #msg1) / 2) + 1), midH - 1)
  mon.write(msg1:sub(1, w))
  mon.setTextColor(colors.white)
  mon.setCursorPos(math.max(1, math.floor((w - #msg2) / 2) + 1), midH + 1)
  mon.write(msg2:sub(1, w))
  mon.setTextColor(colors.gray)
  mon.setCursorPos(math.max(1, math.floor((w - #msg3) / 2) + 1), midH + 2)
  mon.write(msg3:sub(1, w))
end

local function drawMonitor()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  if mode == "list" then
    drawList()
  elseif mode == "confirm_delete" then
    drawList()   -- keep context visible behind the overlay
    drawConfirmDelete()
  elseif mode == "editing" then
    drawEditing()
  elseif mode == "add_prompt" then
    drawAddPrompt()
  end
end

-- ── touch handler ─────────────────────────────────────────────────────────────

local function handleTouch(x, y)
  local w, h = mon.getSize()

  if mode == "confirm_delete" then
    if y == yesButtonRow then
      deleteTopic(currentTopic)
      mode = "list"
      drawMonitor()
    elseif y == noButtonRow then
      mode = "list"
      drawMonitor()
    end
    return
  end

  if mode ~= "list" then return end

  -- [+] add topic
  if y == 1 and x >= addButtonX and x <= addButtonX + 2 then
    mode = "add_prompt"
    drawMonitor()
    -- prompt in terminal
    term.setCursorPos(1, term.getCursorPos())
    write("New topic name (blank to cancel): ")
    local name = read()
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then
      flashMonitor("Cancelled.", colors.gray)
    else
      name = name:gsub("[/\\]", "-")
      local exists = false
      for _, t in ipairs(topics) do if t == name then exists = true end end
      if exists then
        flashMonitor('Topic "' .. name .. '" already exists!', colors.red)
      else
        addTopic(name)
        flashMonitor('Created "' .. name .. '"', colors.lime)
      end
    end
    mode = "list"
    drawMonitor()
    return
  end

  -- [X] delete topic
  if y == 1 and x >= delButtonX and x <= delButtonX + 2 then
    if currentTopic then
      mode = "confirm_delete"
      drawMonitor()
    end
    return
  end

  -- tab strip row
  if y == TAB_ROW then
    -- left arrow
    if tabLeftArrowX and x >= tabLeftArrowX and x <= tabLeftArrowX + 2 then
      tabOffset = math.max(1, tabOffset - 1)
      drawMonitor()
      return
    end
    -- right arrow
    if tabRightArrowX and x >= tabRightArrowX and x <= tabRightArrowX + 2 then
      tabOffset = math.min(#topics, tabOffset + 1)
      drawMonitor()
      return
    end
    -- tab hitboxes
    for _, hb in ipairs(tabHitboxes) do
      if x >= hb.x1 and x <= hb.x2 then
        currentTopic = hb.name
        drawMonitor()
        return
      end
    end
    return
  end

  -- footer row
  if y == h then
    -- [Edit]
    if currentTopic and editButtonX1 and x >= editButtonX1 and x <= editButtonX2 then
      mode = "editing"
      drawMonitor()
      ensureNotesDir()
      shell.run("edit", topicPath(currentTopic))
      mode = "list"
      drawMonitor()
      return
    end
    -- scroll up [^]
    if scrollUpX and x >= scrollUpX and x <= scrollUpX + 2 then
      if scrollOffsets[currentTopic] and scrollOffsets[currentTopic] > 0 then
        scrollOffsets[currentTopic] = scrollOffsets[currentTopic] - 1
        drawMonitor()
      end
      return
    end
    -- scroll down [v]
    if scrollDownX and x >= scrollDownX and x <= scrollDownX + 2 then
      local maxScroll = math.max(0, contentLineCount - 1)
      if scrollOffsets[currentTopic] and scrollOffsets[currentTopic] < maxScroll then
        scrollOffsets[currentTopic] = scrollOffsets[currentTopic] + 1
        drawMonitor()
      end
      return
    end
  end
end

-- ── main ──────────────────────────────────────────────────────────────────────

local monName = peripheral.getName(mon)

loadTopics()
drawMonitor()

term.clear()
term.setCursorPos(1, 1)
print("Notepad running. Press Ctrl+T to stop.")
print("Monitor: " .. monName)
if currentTopic then print("Active topic: " .. currentTopic) end

while true do
  local evt, p1, p2, p3 = os.pullEvent()
  if evt == "monitor_touch" and p1 == monName then
    handleTouch(p2, p3)
  elseif evt == "term_resize" or evt == "monitor_resize" then
    drawMonitor()
  end
end
