-- usage_config.lua
-- Editor for usage_watchlist.cfg and autoscan.cfg. Run with no args or
-- "usage_config add" for a guided prompt, or pass all args at once for
-- scripting. Invalid input is rejected with a reason and re-prompted.

local WATCHLIST_PATH = "usage_watchlist.cfg"
local AUTOSCAN_PATH = "autoscan.cfg"

local DEFAULT_WATCHLIST = {
  { name = "minecraft:iron_ingot",   label = "Iron Ingot",   threshold = 5,  priority = 1 },
  { name = "minecraft:copper_ingot", label = "Copper Ingot", threshold = 5,  priority = 2 },
  { name = "minecraft:redstone",     label = "Redstone",     threshold = 10, priority = 3 },
  { name = "minecraft:gold_ingot",   label = "Gold Ingot",   threshold = 3,  priority = 4 },
}

local DEFAULT_AUTOSCAN = {
  enabled = true,
  minQuantity = 1000,
  depletionPercentPerMin = 15,
  scanInterval = 30,
  topN = 999,
}

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
  local contents = f.readAll()
  f.close()
  local ok, parsed = pcall(textutils.unserialize, contents)
  if ok and type(parsed) == "table" then
    return parsed
  end
  saveTable(path, default)
  return default
end

local function normalizeEntry(item)
  item.threshold = item.threshold or 1
  item.priority = item.priority or 99
  return item
end

local function loadWatchlist()
  local list = loadTable(WATCHLIST_PATH, DEFAULT_WATCHLIST)
  for _, item in ipairs(list) do
    normalizeEntry(item)
  end
  return list
end

local function saveWatchlist(list)
  saveTable(WATCHLIST_PATH, list)
end

local function loadAutoscan()
  return loadTable(AUTOSCAN_PATH, DEFAULT_AUTOSCAN)
end

local function saveAutoscan(cfg)
  saveTable(AUTOSCAN_PATH, cfg)
end

-- Validation helpers. Each returns true/false plus an error string.

local function validItemId(str)
  if not str or str == "" then
    return false, "item id cannot be empty"
  end
  if not str:find(":") then
    return false, "item id needs a namespace, like minecraft:iron_ingot"
  end
  if str:find("%s") then
    return false, "item id cannot contain spaces"
  end
  return true
end

local function validLabel(str)
  if not str or str == "" then
    return false, "label cannot be empty"
  end
  return true
end

local function validNumber(str, minValue)
  local n = tonumber(str)
  if not n then
    return false, "must be a number"
  end
  if minValue and n < minValue then
    return false, "must be at least " .. minValue
  end
  return true, n
end

-- Prompts a question, validates the answer with validatorFn, and keeps
-- re-asking until a valid answer is given. validatorFn returns ok, value_or_error.
local function promptUntilValid(question, validatorFn)
  while true do
    print(question)
    write("> ")
    local answer = read()
    local ok, valueOrErr = validatorFn(answer)
    if ok then
      return (valueOrErr ~= nil and valueOrErr) or answer
    else
      print("Invalid input: " .. tostring(valueOrErr))
      print("")
    end
  end
end

local function interactiveAdd()
  local list = loadWatchlist()

  print("Adding a new watchlist item. Ctrl+T cancels.")
  print("")

  local itemId = promptUntilValid("Item id (example: minecraft:iron_ingot):", validItemId)

  for _, item in ipairs(list) do
    if item.name == itemId then
      print(item.label .. " is already on the watchlist. Nothing added.")
      return
    end
  end

  local label = promptUntilValid("Display label (example: Iron Ingot):", validLabel)
  local threshold = promptUntilValid("Threshold, items per minute, whole number:",
    function(s) return validNumber(s, 0) end)
  local priority = promptUntilValid("Priority, 1 is highest, whole number:",
    function(s) return validNumber(s, 1) end)

  table.insert(list, {
    name = itemId,
    label = label,
    threshold = math.floor(tonumber(threshold)),
    priority = math.floor(tonumber(priority)),
  })
  saveWatchlist(list)

  print("")
  print("Added " .. label .. " (" .. itemId .. "), threshold " .. math.floor(tonumber(threshold))
    .. "/min, priority " .. math.floor(tonumber(priority)))
  print("Monitor picks this up within one poll cycle, no restart needed.")
end

local function addWithArgs(itemId, label, thresholdStr, priorityStr)
  local list = loadWatchlist()

  local ok, err = validItemId(itemId)
  if not ok then
    print("Invalid item id: " .. err)
    return
  end

  ok, err = validLabel(label)
  if not ok then
    print("Invalid label: " .. err)
    return
  end

  local thresholdOk, thresholdVal = validNumber(thresholdStr, 0)
  if not thresholdOk then
    print("Invalid threshold: " .. thresholdVal)
    return
  end

  local priorityOk, priorityVal = validNumber(priorityStr, 1)
  if not priorityOk then
    print("Invalid priority: " .. priorityVal)
    return
  end

  for _, item in ipairs(list) do
    if item.name == itemId then
      print(item.label .. " is already on the watchlist.")
      return
    end
  end

  table.insert(list, {
    name = itemId,
    label = label,
    threshold = math.floor(thresholdVal),
    priority = math.floor(priorityVal),
  })
  saveWatchlist(list)
  print("Added " .. label .. " (" .. itemId .. "), threshold " .. math.floor(thresholdVal)
    .. "/min, priority " .. math.floor(priorityVal))
end

local function printList()
  local list = loadWatchlist()
  table.sort(list, function(a, b) return a.priority < b.priority end)
  if #list == 0 then
    print("Watchlist is empty.")
    return
  end
  for _, item in ipairs(list) do
    print(string.format("p%d  %s  (%s)  threshold %d/min",
      item.priority, item.label, item.name, item.threshold))
  end
end

local function removeItem(itemId)
  if not itemId then
    print("Usage: usage_config remove item_id")
    return
  end
  local list = loadWatchlist()
  local found = false
  for i, item in ipairs(list) do
    if item.name == itemId then
      table.remove(list, i)
      found = true
      break
    end
  end
  if found then
    saveWatchlist(list)
    print("Removed " .. itemId)
  else
    print(itemId .. " was not on the watchlist.")
  end
end

local function setField(field, itemId, rawValue)
  local list = loadWatchlist()
  local ok, value = validNumber(rawValue, field == "priority" and 1 or 0)
  if not ok then
    print("Invalid " .. field .. ": " .. value)
    return
  end
  local found = false
  for _, item in ipairs(list) do
    if item.name == itemId then
      item[field] = math.floor(value)
      found = true
      break
    end
  end
  if found then
    saveWatchlist(list)
    print("Set " .. field .. " " .. math.floor(value) .. " for " .. itemId)
  else
    print(itemId .. " was not on the watchlist.")
  end
end

local function printAutoscan()
  local cfg = loadAutoscan()
  print("Auto-scan enabled: " .. tostring(cfg.enabled))
  print("Min quantity tracked: " .. cfg.minQuantity)
  print("Depletion alarm threshold: " .. cfg.depletionPercentPerMin .. "%/min")
  print("Scan interval: " .. cfg.scanInterval .. "s")
  print("Top movers shown: " .. (cfg.topN or 999))
end

local function autoscanCommand(args)
  local sub = args[1]
  local cfg = loadAutoscan()

  if sub == "on" then
    cfg.enabled = true
    saveAutoscan(cfg)
    print("Auto-scan enabled.")
  elseif sub == "off" then
    cfg.enabled = false
    saveAutoscan(cfg)
    print("Auto-scan disabled.")
  elseif sub == "minqty" then
    local ok, value = validNumber(args[2], 1)
    if not ok then
      print("Invalid minimum quantity: " .. value)
      return
    end
    cfg.minQuantity = math.floor(value)
    saveAutoscan(cfg)
    print("Min quantity set to " .. cfg.minQuantity)
  elseif sub == "percent" then
    local ok, value = validNumber(args[2], 0.1)
    if not ok then
      print("Invalid percent: " .. value)
      return
    end
    cfg.depletionPercentPerMin = value
    saveAutoscan(cfg)
    print("Depletion threshold set to " .. cfg.depletionPercentPerMin .. "%/min")
  elseif sub == "interval" then
    local ok, value = validNumber(args[2], 5)
    if not ok then
      print("Invalid interval: " .. value)
      return
    end
    cfg.scanInterval = math.floor(value)
    saveAutoscan(cfg)
    print("Scan interval set to " .. cfg.scanInterval .. "s")
  elseif sub == "topn" then
    local ok, value = validNumber(args[2], 1)
    if not ok then
      print("Invalid top N: " .. value)
      return
    end
    cfg.topN = math.floor(value)
    saveAutoscan(cfg)
    print("Top movers count set to " .. cfg.topN)
  else
    printAutoscan()
    print("")
    print("Usage:")
    print("  usage_config autoscan on")
    print("  usage_config autoscan off")
    print("  usage_config autoscan minqty 1000")
    print("  usage_config autoscan percent 15")
    print("  usage_config autoscan interval 30")
    print("  usage_config autoscan topn 8   (cap the list, default fills screen)")
  end
end

local args = { ... }
local command = args[1]

if command == "list" or command == nil then
  printList()

elseif command == "add" then
  if args[2] and args[3] and args[4] and args[5] then
    addWithArgs(args[2], args[3], args[4], args[5])
  else
    interactiveAdd()
  end

elseif command == "remove" then
  removeItem(args[2])

elseif command == "priority" then
  setField("priority", args[2], args[3])

elseif command == "threshold" then
  setField("threshold", args[2], args[3])

elseif command == "autoscan" then
  autoscanCommand({ args[2], args[3] })

elseif command == "reset" then
  saveWatchlist(DEFAULT_WATCHLIST)
  print("Watchlist reset to defaults.")

else
  print("Unknown command: " .. tostring(command))
  print("Usage:")
  print("  usage_config list")
  print("  usage_config add                (guided prompts)")
  print("  usage_config add id label threshold priority")
  print("  usage_config remove item_id")
  print("  usage_config priority item_id new_priority")
  print("  usage_config threshold item_id new_threshold")
  print("  usage_config autoscan ...")
  print("  usage_config reset")
end