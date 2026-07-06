-- music_player.lua
-- DFPWM audio player with monitor UI.
-- Place: computer with a speaker and advanced monitor attached.
-- Drop .dfpwm files into the 'music/' folder on this computer.
-- Touch [<<]/[>>] to cycle tracks; [PLAY]/[STOP] to control playback.

local MUSIC_DIR = "music"

local speaker = peripheral.find("speaker")
local mon     = peripheral.find("monitor")

if not speaker then
  error("No speaker found. Attach a speaker peripheral to this computer.")
end
if not mon then
  error("No monitor found. Attach an advanced monitor to this computer.")
end

mon.setTextScale(0.5)
local w, h = mon.getSize()
local hasColor = mon.isColor and mon.isColor()

local COL_BG     = colors.black
local COL_TEXT   = colors.white
local COL_HEADER = colors.cyan
local COL_DIM    = colors.gray
local COL_BUTTON = colors.yellow
local COL_PLAY   = colors.lime
local COL_STOP   = colors.red

local function setColors(fg, bg)
  if hasColor then
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
  end
end

local function clearScreen()
  mon.setBackgroundColor(COL_BG)
  mon.clear()
end

local function writeAt(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  setColors(fg or COL_TEXT, bg or COL_BG)
  mon.write(text)
end

local function centerText(y, text, fg, bg)
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(x, y, text, fg, bg)
end

-- Scan MUSIC_DIR for .dfpwm files, sorted alphabetically.
local function scanTracks()
  local list = {}
  if not fs.isDir(MUSIC_DIR) then
    fs.makeDir(MUSIC_DIR)
  end
  for _, file in ipairs(fs.list(MUSIC_DIR)) do
    if file:match("%.dfpwm$") then
      local name = file:gsub("%.dfpwm$", "")
      table.insert(list, { name = name, path = fs.combine(MUSIC_DIR, file) })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local tracks = scanTracks()
local idx       = 1
local isPlaying = false
local showCredit = false

-- Buttons: centered on the bottom row.
-- PLAY and STOP must be the same length so the touch area is stable.
local PREV_LABEL = "[ << ]"
local PLAY_LABEL = "[ PLAY ]"
local STOP_LABEL = "[ STOP ]"
local NEXT_LABEL = "[ >> ]"

local BTN_Y  = h
local totalW = #PREV_LABEL + 1 + #PLAY_LABEL + 1 + #NEXT_LABEL
local startX = math.max(1, math.floor((w - totalW) / 2) + 1)
local PREV_X = startX
local PLAY_X = startX + #PREV_LABEL + 1
local NEXT_X = PLAY_X + #PLAY_LABEL + 1

local function inBtn(x, y, bx, by, label)
  return y == by and x >= bx and x < bx + #label
end

local function drawUI()
  clearScreen()
  writeAt(1, 1, "MUSIC PLAYER", COL_HEADER, COL_BG)
  writeAt(w, 1, "?", COL_BUTTON, COL_BG)
  writeAt(1, 2, string.rep("-", w), COL_DIM, COL_BG)

  if showCredit then
    centerText(math.floor(h / 2), "Created by xransum", COL_HEADER, COL_BG)
  elseif #tracks == 0 then
    centerText(math.floor(h / 2),     "No tracks in /" .. MUSIC_DIR, COL_DIM, COL_BG)
    centerText(math.floor(h / 2) + 1, "Add .dfpwm files and reboot", COL_DIM, COL_BG)
  else
    -- Track name (truncate if wider than monitor)
    local name = tracks[idx].name
    if #name > w - 4 then name = name:sub(1, w - 7) .. "..." end
    centerText(4, name, COL_TEXT, COL_BG)
    centerText(5, idx .. " / " .. #tracks, COL_DIM, COL_BG)

    if isPlaying then
      centerText(7, ">> Playing", COL_PLAY, COL_BG)
    else
      centerText(7, "|| Stopped", COL_DIM, COL_BG)
    end
  end

  -- Bottom divider + buttons
  writeAt(1, h - 1, string.rep("-", w), COL_DIM, COL_BG)
  writeAt(PREV_X, BTN_Y, PREV_LABEL, COL_BUTTON, COL_BG)
  if isPlaying then
    writeAt(PLAY_X, BTN_Y, STOP_LABEL, COL_STOP, COL_BG)
  else
    writeAt(PLAY_X, BTN_Y, PLAY_LABEL, COL_PLAY, COL_BG)
  end
  writeAt(NEXT_X, BTN_Y, NEXT_LABEL, COL_BUTTON, COL_BG)
end

-- Plays the track at `path` to completion.
-- Runs as one branch of parallel.waitForAny, so it is killed cleanly
-- when the touch-handler branch returns (stop/prev/next pressed).
local function playTrack(path)
  local dfpwm = require("cc.audio.dfpwm")
  local decoder = dfpwm.make_decoder()
  local f = fs.open(path, "rb")
  if not f then return end
  while true do
    local chunk = f.read(16 * 1024)
    if not chunk then break end
    local buf = decoder(chunk)
    while not speaker.playAudio(buf) do
      os.pullEvent("speaker_audio_empty")
    end
  end
  f.close()
end

-- Main loop: draw → wait for touch → act → repeat.
local pendingAction = nil

while true do
  drawUI()

  if #tracks == 0 then
    -- Nothing to play; re-scan periodically in case files are added.
    sleep(5)
    tracks = scanTracks()
  else
    local _, _, x, y = os.pullEvent("monitor_touch")

    if x == w and y == 1 then
      showCredit = not showCredit
    elseif inBtn(x, y, PREV_X, BTN_Y, PREV_LABEL) then
      -- Cycle backwards (wraps)
      idx = ((idx - 2) % #tracks) + 1

    elseif inBtn(x, y, NEXT_X, BTN_Y, NEXT_LABEL) then
      -- Cycle forwards (wraps)
      idx = (idx % #tracks) + 1

    elseif inBtn(x, y, PLAY_X, BTN_Y, PLAY_LABEL) and not isPlaying then
      -- Start playback. Run playTrack + touch-handler in parallel;
      -- whichever returns first wins (touch handler returns on stop/prev/next,
      -- playTrack returns when the file is exhausted).
      isPlaying = true
      drawUI()
      pendingAction = nil

      parallel.waitForAny(
        function()
          playTrack(tracks[idx].path)
        end,
        function()
          while true do
            local _, _, tx, ty = os.pullEvent("monitor_touch")
            if tx == w and ty == 1 then
              showCredit = not showCredit
              drawUI()
            elseif inBtn(tx, ty, PLAY_X, BTN_Y, STOP_LABEL) then
              pendingAction = "stop";  return
            elseif inBtn(tx, ty, PREV_X, BTN_Y, PREV_LABEL) then
              pendingAction = "prev";  return
            elseif inBtn(tx, ty, NEXT_X, BTN_Y, NEXT_LABEL) then
              pendingAction = "next";  return
            end
          end
        end
      )

      -- Always stop the speaker so lingering buffered audio clears.
      speaker.stop()
      isPlaying = false

      -- Apply the navigation action that caused the stop (if any).
      if pendingAction == "prev" then
        idx = ((idx - 2) % #tracks) + 1
      elseif pendingAction == "next" then
        idx = (idx % #tracks) + 1
      end
      -- pendingAction == nil  → track finished naturally (stay on same track)
      -- pendingAction == "stop" → user stopped (stay on same track)
    end
  end
end
