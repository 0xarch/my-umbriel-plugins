--!nonstrict
-- Better Launchpad - the built-in launcher as a standalone plugin.
--
-- The panel mirrors the Simple layout: a search field, optional category
-- chips, and a result list or five-column app grid. Applications, calculator,
-- emoji, wallpaper, session, windows, and the `/` provider overview are all
-- implemented locally on top of the plugin API.
--
-- Durable usage history lives under pluginDataDir(); the built-in launcher's
-- state files are only read, never written.

local PROVIDER_ORDER = { "calculator", "emoji", "wallpaper", "session", "windows" }

local PROVIDER_DEFAULT_PREFIX = {
  calculator = "calc",
  emoji = "emo",
  wallpaper = "wall",
  session = "session",
  windows = "win",
}

local PROVIDER_DEFAULT_GLOBAL = {
  calculator = true,
  emoji = false,
  wallpaper = false,
  session = false,
  windows = false,
}

local PROVIDER_CANONICAL = {
  calculator = "Calculator",
  emoji = "Emoji",
  wallpaper = "Wallpaper",
  session = "Session",
  windows = "Windows",
}

local PROVIDER_GLYPH = {
  calculator = "calculator",
  emoji = "mood-smile",
  wallpaper = "wallpaper",
  session = "power",
  windows = "app-window",
  overview = "sparkles",
}

local APP_CATEGORIES = {
  { id = "internet", glyph = "world", label = "categories.internet", tokens = { "Network" } },
  { id = "multimedia", glyph = "player-play", label = "categories.multimedia", tokens = { "AudioVideo", "Audio", "Video" } },
  { id = "development", glyph = "code", label = "categories.development", tokens = { "Development" } },
  { id = "games", glyph = "device-gamepad-2", label = "categories.games", tokens = { "Game" } },
  { id = "graphics", glyph = "photo", label = "categories.graphics", tokens = { "Graphics" } },
  { id = "office", glyph = "briefcase", label = "categories.office", tokens = { "Office" } },
  { id = "education", glyph = "school", label = "categories.education", tokens = { "Education", "Science" } },
  { id = "system", glyph = "settings", label = "categories.system", tokens = { "System" } },
  { id = "utilities", glyph = "tool", label = "categories.utilities", tokens = { "Utility", "Settings" } },
}

local EMOJI_CATEGORIES = {
  { id = "people", glyph = "mood-smile", label = "categories.emoji.people" },
  { id = "animals", glyph = "paw", label = "categories.emoji.animals" },
  { id = "food", glyph = "apple", label = "categories.emoji.food" },
  { id = "travel", glyph = "map", label = "categories.emoji.travel" },
  { id = "activity", glyph = "ball-football", label = "categories.emoji.activity" },
  { id = "objects", glyph = "device-floppy", label = "categories.emoji.objects" },
  { id = "symbols", glyph = "at", label = "categories.emoji.symbols" },
  { id = "flags", glyph = "flag", label = "categories.emoji.flags" },
  { id = "nature", glyph = "leaf", label = "categories.emoji.nature" },
}

local IMAGE_EXTENSIONS = {
  jpg = true, jpeg = true, png = true, webp = true, avif = true,
  gif = true, bmp = true, tif = true, tiff = true,
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function T(key, fallback, subst)
  local value = nil
  if noctalia.tr ~= nil then
    value = noctalia.tr(key, subst)
  end
  if type(value) ~= "string" or value == "" or value == key then
    return fallback or key
  end
  return value
end

local function startsWith(value, prefix)
  return value ~= nil and prefix ~= nil and value:sub(1, #prefix) == prefix
end

local function lower(value)
  return type(value) == "string" and value:lower() or ""
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function setting(path, fallback)
  local value = noctalia.getSetting(path)
  if value == nil then
    return fallback
  end
  return value
end

local function boolSetting(path, fallback)
  local value = setting(path, fallback)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "string" then
    return value == "true"
  end
  return fallback
end

local function splitSemicolon(value)
  local out = {}
  if type(value) ~= "string" then
    return out
  end
  for rawToken in value:gmatch("([^;]+)") do
    local token = trim(rawToken)
    if token ~= "" then
      out[#out + 1] = token
    end
  end
  return out
end

local function containsToken(list, token)
  for _, item in ipairs(list) do
    if item == token then
      return true
    end
  end
  return false
end

local function readJson(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" or content == "" then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, content)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

local function readJsonText(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, text)
  if ok then
    return value
  end
  return nil
end

local function writeJson(path, value)
  if type(path) ~= "string" or path == "" then
    return
  end
  local encoded = noctalia.json.encode(value, true)
  if type(encoded) == "string" and encoded ~= "" then
    noctalia.writeFile(path, encoded)
  end
end

-- ── runtime state ───────────────────────────────────────────────────────────

local isOpen = false
local query = ""
local inputRev = 0
local scrollRev = 0
local selected = 1
local hoverIndex = nil
local keyboardFocus = true
local results = {}
local providerId = "Applications"
local providerQuery = ""
local categories = {}
local catFilter = "all"
local config = nil
local apps = nil
local appsAt = 0
local appScan = nil
local appCategories = nil
local emojiState = { list = nil, at = 0 }
local wallpapers = nil
local wallpapersAt = 0
local windowState = { list = nil, at = 0, loading = false }
local calc = { result = nil, expression = nil, seq = 0, pending = false }
local iconCache = {}
local usageBuiltinCounts = {}
local usageBuiltinRecent = {}
local usageOwn = { counts = {}, recent = {} }
local usageOwnPath = nil
local pinnedRank = {}
local pinnedSet = {}
local orderRank = {}
local order = nil
local orderPath = nil
local mode = "normal"
local editDragMode = "swap"
local hoverFolder = false
local editShown = 0
local lastRight = { index = nil, at = 0 }
local forceList = false
local resultsShown = 0
-- Frame-loop flags: a tile list is truncated, a render is owed after a refresh,
-- or resolved icons are waiting to be drawn.
local flags = { more = false, render = false, icons = false, apps = false }
local folderOpen = nil
local folderResults = {}

-- Building the full tree for a large catalog overruns the 25 ms callback
-- budget, so tiles appear in chunks: each frame adds RESULTS_PER_FRAME more
-- results until the whole list is in the scroll.
local RESULTS_PER_FRAME = 10

-- A second right-click on the same app within this window enters edit mode.
local RIGHT_CLICK_WINDOW = 2

-- Forward declarations for functions used by asynchronous callbacks and by
-- helpers defined before them.
local refresh
local resolvePinned
local focusInput
local renderNormal
local resultNodesFrom
local openResultMenu
local openFolder
local closeFolder
local enterEditMode
local exitEditMode

-- ── settings ────────────────────────────────────────────────────────────────

local function loadConfig()
  local launcherSettings = setting("shell.launcher", {})
  local providers = {}
  if type(launcherSettings) == "table" and type(launcherSettings.providers) == "table" then
    providers = launcherSettings.providers
  end

  local function providerConf(id)
    local row = providers[id]
    if type(row) ~= "table" then
      row = {}
    end
    local prefix = row.prefix
    if type(prefix) ~= "string" or prefix == "" then
      prefix = PROVIDER_DEFAULT_PREFIX[id]
    end
    local global = row.global
    if type(global) ~= "boolean" then
      global = PROVIDER_DEFAULT_GLOBAL[id]
    end
    return { prefix = prefix, global = global }
  end

  local pinned = setting("shell.launcher.pinned", {})
  if type(pinned) ~= "table" then
    pinned = {}
  end

  local prefixChar = setting("shell.launcher.provider_prefix", "/")
  if type(prefixChar) ~= "string" or prefixChar == "" then
    prefixChar = "/"
  end

  local cfg = {
    appGrid = boolSetting("shell.launcher.app_grid", false),
    categories = boolSetting("shell.launcher.categories", true),
    showIcons = boolSetting("shell.launcher.show_icons", true),
    compact = boolSetting("shell.launcher.compact", false),
    sortByUsage = boolSetting("shell.launcher.sort_by_usage", true),
    trackUsage = boolSetting("shell.launcher.track_usage", true),
    autoPaste = setting("shell.launcher.auto_paste", "auto"),
    providerPrefix = prefixChar,
    pinned = pinned,
    providers = {},
  }
  for _, id in ipairs(PROVIDER_ORDER) do
    cfg.providers[id] = providerConf(id)
  end
  return cfg
end

local function stateHome()
  local xdg = noctalia.getenv("XDG_STATE_HOME")
  if type(xdg) == "string" and xdg ~= "" then
    return xdg
  end
  local home = noctalia.getenv("HOME")
  if type(home) == "string" and home ~= "" then
    return home .. "/.local/state"
  end
  return nil
end

local function loadUsage()
  local base = stateHome()
  if base ~= nil then
    usageBuiltinCounts = readJson(base .. "/noctalia/usage_counts.json") or {}
    usageBuiltinRecent = readJson(base .. "/noctalia/recently_used.json") or {}
  else
    usageBuiltinCounts = {}
    usageBuiltinRecent = {}
  end

  local dataDir = noctalia.pluginDataDir()
  if type(dataDir) == "string" and dataDir ~= "" then
    usageOwnPath = dataDir .. "/usage.json"
    usageOwn = readJson(usageOwnPath) or { counts = {}, recent = {} }
  else
    usageOwnPath = nil
    usageOwn = { counts = {}, recent = {} }
  end

  if type(usageOwn.counts) ~= "table" then
    usageOwn.counts = {}
  end
  if type(usageOwn.recent) ~= "table" then
    usageOwn.recent = {}
  end
end

local function usageCount(provider, id)
  local builtin = 0
  local own = 0
  if type(usageBuiltinCounts[provider]) == "table" then
    builtin = tonumber(usageBuiltinCounts[provider][id]) or 0
  end
  if type(usageOwn.counts[provider]) == "table" then
    own = tonumber(usageOwn.counts[provider][id]) or 0
  end
  if own > builtin then
    return own
  end
  return builtin
end

local function recentList(provider)
  local out = {}
  local seen = {}
  local function append(list)
    if type(list) ~= "table" then
      return
    end
    for _, id in ipairs(list) do
      if type(id) == "string" and not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  append(usageOwn.recent[provider])
  append(usageBuiltinRecent[provider])
  return out
end

local function recentIndex(provider)
  local index = {}
  local list = recentList(provider)
  for i, id in ipairs(list) do
    index[id] = #list - i + 1
  end
  return index
end

local function saveUsage()
  if usageOwnPath ~= nil then
    writeJson(usageOwnPath, usageOwn)
  end
end

local function recordUsage(provider, id)
  if config == nil or not config.trackUsage or type(id) ~= "string" or id == "" then
    return
  end
  usageOwn.counts[provider] = usageOwn.counts[provider] or {}
  usageOwn.counts[provider][id] = usageCount(provider, id) + 1

  local list = recentList(provider)
  local nextList = { id }
  for _, item in ipairs(list) do
    if item ~= id and #nextList < 20 then
      nextList[#nextList + 1] = item
    end
  end
  usageOwn.recent[provider] = nextList
  saveUsage()
end

-- ── layout order ────────────────────────────────────────────────────────────

-- Durable layout: one row per entry, in display order. Today every row is an
-- application (`{ type = "app", id = <desktop path>, pinned = <bool?> }`); the
-- `type` field and the preserved extra keys reserve room for folder rows, so a
-- later version can add `{ type = "folder", id = ..., name = ..., entries = ... }`
-- without invalidating the store.
local ORDER_VERSION = 1

local function orderFile()
  if orderPath == nil then
    local dataDir = noctalia.pluginDataDir()
    if type(dataDir) == "string" and dataDir ~= "" then
      orderPath = dataDir .. "/order.json"
    end
  end
  return orderPath
end

-- Folder rows carry `{ type = "folder", id = "folder-N", name = ..., entries = { paths } }`;
-- members are desktop paths, in the folder's own display order. Folders never
-- nest: a member path is always an application.
local function normalizeFolderEntries(value)
  local entries = {}
  if type(value) == "table" then
    for _, path in ipairs(value) do
      if type(path) == "string" and path ~= "" then
        entries[#entries + 1] = path
      end
    end
  end
  return entries
end

local function normalizeOrderRow(row)
  if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" then
    -- A hand-written folder may omit its id; loadOrder assigns one afterwards.
    if not (type(row) == "table" and row.type == "folder") then
      return nil
    end
  end
  local out = {}
  for key, value in pairs(row) do
    if key ~= "type" and key ~= "id" and key ~= "pinned" and key ~= "entries" then
      out[key] = value
    end
  end
  out.type = type(row.type) == "string" and row.type or "app"
  if out.type == "folder" then
    out.entries = normalizeFolderEntries(row.entries)
  end
  if type(row.id) == "string" and row.id ~= "" then
    out.id = row.id
  end
  if row.pinned == true then
    out.pinned = true
  elseif row.pinned == false then
    out.pinned = false
  end
  return out
end

local saveOrder

local function nextFolderId(rows)
  local used = {}
  for _, row in ipairs(rows or loadOrder().entries) do
    if row.type == "folder" and type(row.id) == "string" then
      used[row.id] = true
    end
  end
  local n = 1
  while used["folder-" .. n] do
    n = n + 1
  end
  return "folder-" .. n
end

local function loadOrder()
  if order ~= nil then
    return order
  end
  local rows = {}
  local path = orderFile()
  local stored = path ~= nil and readJson(path) or nil
  if type(stored) == "table" and type(stored.entries) == "table" then
    for _, row in ipairs(stored.entries) do
      local normalized = normalizeOrderRow(row)
      if normalized ~= nil then
        rows[#rows + 1] = normalized
      end
    end
  end
  order = { version = ORDER_VERSION, entries = rows }
  -- Give id-less folders (hand-written rows) a stable identity, then persist.
  local assigned = false
  for _, row in ipairs(order.entries) do
    if row.type == "folder" and (row.id == nil or row.id == "") then
      row.id = nextFolderId(order.entries)
      assigned = true
    end
  end
  if assigned then
    saveOrder()
  end
  return order
end

saveOrder = function()
  local path = orderFile()
  if path == nil then
    return false
  end
  writeJson(path, loadOrder())
  return true
end

local function orderRowIndex(id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  for index, row in ipairs(loadOrder().entries) do
    if row.id == id then
      return index
    end
  end
  return nil
end

local function reindexOrder()
  orderRank = {}
  local rank = 0
  for _, row in ipairs(loadOrder().entries) do
    if row.type == "app" and orderRank[row.id] == nil then
      rank = rank + 1
      orderRank[row.id] = rank
    end
  end
end

local function findAppByPath(path)
  for _, entry in ipairs(apps or {}) do
    if entry.path == path then
      return entry
    end
  end
  return nil
end

-- The built-in launcher stores pins as ids; accept the same spellings here.
local function findAppForPin(pin)
  local wanted = pin:gsub("%.desktop$", "")
  local wantedLower = wanted:lower()
  for _, entry in ipairs(apps or {}) do
    if entry.id == wanted or entry.id:lower() == wantedLower
      or entry.path == pin
      or (entry.startupWmClass ~= "" and (entry.startupWmClass == wanted or entry.startupWmClass:lower() == wantedLower)) then
      return entry
    end
  end
  return nil
end

-- Reconcile the stored layout with the scan: seed the shell's pinned list the
-- first time an app is seen, then append every app that is not stored yet.
-- Missing entries are kept so an uninstalled app returns to its old slot.
local function syncOrder()
  local store = loadOrder()
  local byId = {}
  for _, row in ipairs(store.entries) do
    if row.type == "app" and byId[row.id] == nil then
      byId[row.id] = row
    end
  end

  local changed = false
  local newPins = {}
  for _, pin in ipairs(config ~= nil and config.pinned or {}) do
    if type(pin) == "string" and pin ~= "" then
      local match = findAppForPin(pin)
      if match ~= nil then
        local row = byId[match.path]
        if row == nil then
          row = { type = "app", id = match.path, pinned = true }
          newPins[#newPins + 1] = row
          byId[match.path] = row
          changed = true
        elseif row.pinned == nil then
          row.pinned = true
          changed = true
        end
      end
    end
  end
  for index = #newPins, 1, -1 do
    table.insert(store.entries, 1, newPins[index])
  end

  local seen = {}
  for _, row in ipairs(store.entries) do
    if row.type == "app" then
      seen[row.id] = true
    elseif row.type == "folder" then
      for _, path in ipairs(row.entries or {}) do
        seen[path] = true
      end
    end
  end
  for _, entry in ipairs(apps or {}) do
    if not seen[entry.path] then
      store.entries[#store.entries + 1] = { type = "app", id = entry.path }
      seen[entry.path] = true
      changed = true
    end
  end

  if changed then
    saveOrder()
  end
  reindexOrder()
end

-- ── folder mutations ────────────────────────────────────────────────────────

-- Create a folder holding `paths` (in that order) at the position of its first
-- member; the members' top-level rows are removed, so an application lives in
-- exactly one place. Returns the new row.
-- `anchorPath` places the folder at that row's slot (the drop target); without
-- it the folder takes its first member's slot.
local function createFolderWithApps(paths, name, anchorPath)
  local function uniqueName(base, entries)
    local used = {}
    for _, row in ipairs(entries) do
      if row.type == "folder" and type(row.name) == "string" then
        used[row.name] = true
      end
    end
    if not used[base] then
      return base
    end
    local n = 2
    while used[base .. " " .. tostring(n)] do
      n = n + 1
    end
    return base .. " " .. tostring(n)
  end

  if type(paths) ~= "table" or #paths == 0 then
    return nil
  end
  local store = loadOrder()
  local wanted = {}
  for _, path in ipairs(paths) do
    if type(path) == "string" and path ~= "" and wanted[path] == nil then
      wanted[path] = true
    end
  end

  local anchor = nil
  local members = {}
  for index, row in ipairs(store.entries) do
    if row.type == "app" and wanted[row.id] then
      if row.id == anchorPath then
        anchor = index
      end
      members[#members + 1] = row.id
    end
  end
  if #members == 0 then
    return nil
  end
  if anchor == nil then
    for index, row in ipairs(store.entries) do
      if row.type == "app" and wanted[row.id] then
        anchor = index
        break
      end
    end
  end
  -- Members follow the order the caller gave, not the store order.
  local ordered = {}
  local memberSet = {}
  for _, path in ipairs(paths) do
    if memberSet[path] == nil and wanted[path] then
      memberSet[path] = true
      ordered[#ordered + 1] = path
    end
  end

  local folder = {
    type = "folder",
    id = nextFolderId(store.entries),
    name = type(name) == "string" and name ~= "" and name
      or uniqueName(T("folder.new", "New Folder"), store.entries),
    entries = ordered,
  }
  for index = #store.entries, 1, -1 do
    local row = store.entries[index]
    if row.type == "app" and wanted[row.id] then
      table.remove(store.entries, index)
      if index < anchor then
        anchor = anchor - 1
      end
    end
  end
  table.insert(store.entries, anchor or 1, folder)
  saveOrder()
  reindexOrder()
  return folder
end

local function folderRow(folderId)
  if type(folderId) ~= "string" then
    return nil
  end
  for _, row in ipairs(loadOrder().entries) do
    if row.type == "folder" and row.id == folderId then
      return row
    end
  end
  return nil
end

local function addToFolder(folderId, path)
  local row = folderRow(folderId)
  if row == nil or type(path) ~= "string" or path == "" then
    return false
  end
  for _, member in ipairs(row.entries) do
    if member == path then
      return false
    end
  end
  row.entries[#row.entries + 1] = path
  -- The app's top-level row goes away: membership is exclusive.
  local index = orderRowIndex(path)
  if index ~= nil and loadOrder().entries[index].type == "app" then
    table.remove(loadOrder().entries, index)
  end
  saveOrder()
  reindexOrder()
  return true
end

-- Send every member back to the top level at the folder's position, then drop
-- the folder itself.
local function disbandFolder(folderId)
  local index = orderRowIndex(folderId)
  local row = folderRow(folderId)
  if index == nil or row == nil then
    return false
  end
  local store = loadOrder()
  table.remove(store.entries, index)
  for offset, path in ipairs(row.entries or {}) do
    table.insert(store.entries, index + offset - 1, { type = "app", id = path })
  end
  saveOrder()
  reindexOrder()
  return true
end

local function removeFromFolder(folderId, path)
  local row = folderRow(folderId)
  if row == nil then
    return false
  end
  for index, member in ipairs(row.entries) do
    if member == path then
      table.remove(row.entries, index)
      -- An emptied folder disappears; its spot keeps the remaining rows.
      if #row.entries == 0 then
        local position = orderRowIndex(folderId)
        if position ~= nil then
          table.remove(loadOrder().entries, position)
        end
      end
      saveOrder()
      reindexOrder()
      return true
    end
  end
  return false
end

local function setPinned(path, pinned)
  local index = orderRowIndex(path)
  if index == nil then
    return false
  end
  local store = loadOrder()
  local row = store.entries[index]
  if row.pinned == pinned then
    return false
  end
  row.pinned = pinned
  if pinned then
    table.remove(store.entries, index)
    local position = 1
    for cursor, item in ipairs(store.entries) do
      if item.type == "app" and item.pinned == true then
        position = cursor + 1
      end
    end
    table.insert(store.entries, position, row)
  end
  saveOrder()
  resolvePinned()
  refresh()
  render()
  return true
end

-- Move one stored row onto another position (edit-mode drag and drop).
local function moveOrderRow(fromId, toPosition)
  local fromPosition = orderRowIndex(fromId)
  local store = loadOrder()
  local target = tonumber(toPosition)
  if fromPosition == nil or target == nil or target < 1 or target > #store.entries then
    return false
  end
  if fromPosition == target then
    return false
  end
  if target > #store.entries + 1 then
    target = #store.entries + 1
  end
  local row = table.remove(store.entries, fromPosition)
  -- The moved row takes the target slot, like the built-in reorder.
  table.insert(store.entries, target, row)
  saveOrder()
  reindexOrder()
  return true
end

-- ── desktop entries ─────────────────────────────────────────────────────────

-- ── application discovery ───────────────────────────────────────────────────

-- Desktop files are parsed by a helper process: a large entry can take longer
-- than the 25 ms callback budget when parsed in Luau.
local APP_SCAN_INTERVAL = 30

local function finishAppScan(list)
  apps = list
  appsAt = os.time()
  appCategories = nil
  syncOrder()
  resolvePinned()
  if isOpen then
    flags.apps = true
    panel.setNeedsFrameTick(true)
  end
end

local function startAppScan()
  if appScan then
    return
  end
  appScan = true

  local dir = noctalia.pluginDir() or "."
  local started = noctalia.runAsync({ "bash", dir .. "/scan-apps.sh" }, function(result)
    appScan = nil
    local list = {}
    if type(result) == "table" and result.exitCode == 0 and type(result.stdout) == "string" then
      local ok, decoded = pcall(noctalia.json.decode, result.stdout)
      if ok and type(decoded) == "table" then
        list = decoded
      end
    end
    finishAppScan(list)
  end, 15000)

  if not started then
    appScan = nil
    finishAppScan({})
  end
end

local function getApplications(force)
  local now = os.time()
  if apps == nil or force or now - appsAt > APP_SCAN_INTERVAL then
    startAppScan()
  end
  return apps or {}
end

local function primaryCategory(categoriesString)
  if type(categoriesString) ~= "string" or categoriesString == "" then
    return nil
  end
  local tokens = splitSemicolon(categoriesString)
  for _, category in ipairs(APP_CATEGORIES) do
    for _, token in ipairs(tokens) do
      if containsToken(category.tokens, token) then
        return category.id
      end
    end
  end
  return nil
end

local function buildAppCategories()
  if appCategories ~= nil then
    return appCategories
  end
  local present = {}
  for _, entry in ipairs(apps or {}) do
    local id = primaryCategory(entry.categories)
    if id ~= nil then
      present[id] = true
    end
  end
  local out = {}
  for _, category in ipairs(APP_CATEGORIES) do
    if present[category.id] then
      out[#out + 1] = category
    end
  end
  appCategories = out
  return out
end

resolvePinned = function()
  pinnedRank = {}
  pinnedSet = {}
  local store = loadOrder()
  local rank = 0
  for _, row in ipairs(store.entries) do
    if row.type == "app" then
      rank = rank + 1
      if row.pinned == true and pinnedSet[row.id] ~= true then
        pinnedSet[row.id] = true
        pinnedRank[row.id] = rank
      end
    end
  end
  reindexOrder()
end

-- ── emoji ───────────────────────────────────────────────────────────────────

local function getEmoji()
  local now = os.time()
  if emojiState.list ~= nil and now - emojiState.at <= 300 then
    return emojiState.list
  end
  local candidates = {
    "/usr/share/noctalia/assets/emoji.json",
    "/usr/local/share/noctalia/assets/emoji.json",
  }
  local home = noctalia.getenv("HOME")
  if home ~= nil then
    candidates[#candidates + 1] = home .. "/.local/share/noctalia/assets/emoji.json"
  end

  local list = nil
  for _, path in ipairs(candidates) do
    list = readJson(path)
    if list ~= nil then
      break
    end
  end
  if type(list) ~= "table" then
    list = {}
  end
  local out = {}
  for _, item in ipairs(list) do
    if type(item) == "table" and type(item.emoji) == "string" and item.emoji ~= "" and type(item.name) == "string" then
      local keywords = {}
      if type(item.keywords) == "table" then
        for _, keyword in ipairs(item.keywords) do
          if type(keyword) == "string" then
            keywords[#keywords + 1] = keyword:lower()
          end
        end
      end
      out[#out + 1] = {
        emoji = item.emoji,
        name = item.name,
        nameLower = item.name:lower(),
        category = item.category or "",
        keywords = keywords,
      }
    end
  end
  emojiState.list = out
  emojiState.at = now
  return out
end

-- ── wallpapers ──────────────────────────────────────────────────────────────

local function isImagePath(path)
  local ext = lower(path:match("%.([%w]+)$") or "")
  return IMAGE_EXTENSIONS[ext] == true
end

local function collectWallpapers()
  local roots = {}
  local seenRoots = {}
  local function addRoot(path)
    if type(path) == "string" and path ~= "" and not seenRoots[path] then
      seenRoots[path] = true
      roots[#roots + 1] = noctalia.expandPath(path)
    end
  end

  local directory = setting("wallpaper.directory", "")
  if type(directory) == "string" and directory ~= "" then
    addRoot(directory)
  else
    local fallback = noctalia.wallpaperDirectory()
    if type(fallback) == "string" then
      addRoot(fallback)
    end
  end
  addRoot(setting("wallpaper.directory_light", ""))
  addRoot(setting("wallpaper.directory_dark", ""))

  local out = {}
  local seen = {}
  local count = 0

  local function walk(dir, depth)
    if count >= 2000 then
      return
    end
    local names = noctalia.listDir(dir)
    if type(names) ~= "table" then
      return
    end
    for _, name in ipairs(names) do
      if count >= 2000 then
        return
      end
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if type(info) == "table" then
        if info.isDir then
          if depth < 6 and name:sub(1, 1) ~= "." then
            walk(path, depth + 1)
          end
        elseif isImagePath(name) and not seen[path] then
          seen[path] = true
          count = count + 1
          out[#out + 1] = {
            path = path,
            name = name,
            nameLower = name:lower(),
            dirName = dir:match("([^/]+)/?$") or "",
          }
        end
      end
    end
  end

  for _, root in ipairs(roots) do
    walk(root, 1)
  end
  table.sort(out, function(a, b)
    if a.nameLower == b.nameLower then
      return a.path < b.path
    end
    return a.nameLower < b.nameLower
  end)
  return out
end

local function getWallpapers()
  local now = os.time()
  if wallpapers == nil or now - wallpapersAt > 60 then
    wallpapers = collectWallpapers()
    wallpapersAt = now
  end
  return wallpapers
end

-- ── windows ─────────────────────────────────────────────────────────────────

local function refreshWindows(force)
  local now = os.time()
  if windowState.loading then
    return
  end
  if not force and windowState.list ~= nil and now - windowState.at <= 5 then
    return
  end
  windowState.loading = true
  local ok = noctalia.runAsync({ "umbriel", "windows", "--json" }, function(result)
    windowState.loading = false
    windowState.at = os.time()
    local list = {}
    if result ~= nil and result.exitCode == 0 and type(result.stdout) == "string" then
      local decoded = readJsonText(result.stdout)
      if type(decoded) == "table" then
        for _, item in ipairs(decoded) do
          if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            list[#list + 1] = {
              id = item.id,
              title = item.title or item.app_id or item.id,
              appId = item.app_id or "",
              focused = item.focused == true,
              minimized = item.minimized == true,
              workspace = item.workspace or "",
            }
          end
        end
      end
    end
    table.sort(list, function(a, b)
      return lower(a.title) < lower(b.title)
    end)
    windowState.list = list
    if isOpen and providerId == "Windows" then
      refresh()
      render()
    end
  end)
  if not ok then
    windowState.loading = false
    windowState.list = {}
  end
end

-- ── session actions ─────────────────────────────────────────────────────────

local SESSION_LABELS = {
  lock = "action.lock",
  logout = "action.logout",
  suspend = "action.suspend",
  lock_and_suspend = "action.lock_and_suspend",
  reboot = "action.reboot",
  reboot_uefi = "action.reboot_uefi",
  shutdown = "action.shutdown",
  command = "action.command",
}

local SESSION_FALLBACK = {
  lock = "Lock",
  logout = "Log out",
  suspend = "Suspend",
  lock_and_suspend = "Lock and suspend",
  reboot = "Reboot",
  reboot_uefi = "Reboot to firmware",
  shutdown = "Shut down",
  command = "Command",
}

local SESSION_ALIASES = {
  lock = "lock screen session",
  logout = "logout log out sign out exit session",
  suspend = "suspend sleep pause",
  lock_and_suspend = "lock and suspend sleep pause",
  reboot = "reboot restart",
  reboot_uefi = "reboot uefi bios firmware setup",
  shutdown = "shutdown shut down power off poweroff",
  command = "custom command action",
}

local SESSION_GLYPHS = {
  lock = "lock",
  logout = "logout",
  suspend = "zzz",
  lock_and_suspend = "lock",
  reboot = "reload",
  reboot_uefi = "reload",
  shutdown = "power",
  command = "terminal-2",
}

local function sessionActions()
  local source = setting("shell.session.actions", nil)
  if type(source) ~= "table" then
    source = {}
  end
  local out = {}
  for index, row in ipairs(source) do
    if type(row) == "table" then
      local action = row.action
      local enabled = row.enabled ~= false
      local command = type(row.command) == "string" and trim(row.command) or ""
      if enabled and type(action) == "string" and action ~= "" and (action ~= "command" or command ~= "") then
        local label = row.label
        if type(label) ~= "string" or label == "" then
          label = T(SESSION_LABELS[action] or "action.command", SESSION_FALLBACK[action] or action)
        end
        out[#out + 1] = {
          index = index,
          action = action,
          label = label,
          glyph = (type(row.glyph) == "string" and row.glyph ~= "" and row.glyph) or SESSION_GLYPHS[action] or "power",
          command = command,
          searchable = lower(label .. " " .. action .. " " .. (SESSION_ALIASES[action] or "") .. " " .. command),
        }
      end
    end
  end
  return out
end

-- ── application launching ───────────────────────────────────────────────────

local function tokenizeCommand(command)
  local args = {}
  local current = {}
  local inSingle = false
  local inDouble = false
  local index = 1
  while index <= #command do
    local ch = command:sub(index, index)
    if ch == "\\" and inDouble and index < #command then
      local nextCh = command:sub(index + 1, index + 1)
      if nextCh == '"' or nextCh == "`" or nextCh == "$" or nextCh == "\\" then
        current[#current + 1] = nextCh
        index = index + 1
      else
        current[#current + 1] = ch
      end
    elseif ch == "'" and not inDouble then
      inSingle = not inSingle
    elseif ch == '"' and not inSingle then
      inDouble = not inDouble
    elseif ch == " " and not inSingle and not inDouble then
      if #current > 0 then
        args[#args + 1] = table.concat(current)
        current = {}
      end
    else
      current[#current + 1] = ch
    end
    index = index + 1
  end
  if #current > 0 then
    args[#args + 1] = table.concat(current)
  end
  return args
end

local function stripFieldCodes(exec)
  local sentinel = "\1"
  local out = exec:gsub("%%%%", sentinel)
  out = out:gsub("%%[fFuUdDnN]", "")
  out = out:gsub("%%[ick]", "")
  out = out:gsub(sentinel, "%%")
  out = out:gsub("%s+$", "")
  return out
end

local function terminalCommand(args)
  local candidates = {}
  local configured = noctalia.getenv("TERMINAL")
  if type(configured) == "string" and configured ~= "" then
    candidates[#candidates + 1] = configured
  end
  for _, name in ipairs({ "foot", "kitty", "alacritty", "wezterm", "xterm" }) do
    candidates[#candidates + 1] = name
  end
  for _, name in ipairs(candidates) do
    if noctalia.commandExists(name) then
      local base = tokenizeCommand(name)
      if #base == 0 then
        base = { name }
      end
      if base[1] == "wezterm" then
        base[#base + 1] = "start"
        base[#base + 1] = "--"
        for _, arg in ipairs(args) do
          base[#base + 1] = arg
        end
      else
        base[#base + 1] = "-e"
        for _, arg in ipairs(args) do
          base[#base + 1] = arg
        end
      end
      return base
    end
  end
  return args
end

local function launchExec(entry)
  local command = stripFieldCodes(entry.exec)
  if command == "" then
    return false
  end
  local args = tokenizeCommand(command)
  if #args == 0 then
    return false
  end
  if entry.terminal then
    args = terminalCommand(args)
  elseif args[1]:find("=", 1, true) ~= nil and not args[1]:find("/", 1, true) then
    table.insert(args, 1, "env")
  end
  return noctalia.runAsync(args)
end

local function launchApplication(entry)
  recordUsage("Applications", entry.path)
  local gio = noctalia.commandExists("gio")
  if gio then
    local ok = noctalia.runAsync({ "gio", "launch", entry.path }, function(result)
      if result ~= nil and result.exitCode ~= 0 then
        launchExec(entry)
      end
    end)
    if ok then
      return true
    end
  end
  return launchExec(entry)
end

-- ── result building ─────────────────────────────────────────────────────────

local function fuzzy(pattern, text)
  if pattern == "" then
    return 0
  end
  local score = nil
  if noctalia.fuzzyScore ~= nil then
    score = noctalia.fuzzyScore(pattern, text)
  end
  if score == nil then
    return nil
  end
  return score
end

local function scoreList(pattern, list, weight)
  local best = nil
  for _, item in ipairs(list) do
    local score = fuzzy(pattern, lower(item))
    if score ~= nil then
      local weighted = score * weight
      if best == nil or weighted > best then
        best = weighted
      end
    end
  end
  return best
end

local function scoreApplication(entry, pattern)
  local score = nil

  local nameScore = fuzzy(pattern, entry.nameLower)
  if nameScore ~= nil then
    score = nameScore * 5 + 3000
    if startsWith(entry.nameLower, pattern) then
      score = score + 500
    end
  end

  for _, alias in ipairs(entry.searchNames or {}) do
    local aliasScore = fuzzy(pattern, alias)
    if aliasScore ~= nil then
      local weighted = aliasScore * 5 + 1500
      if score == nil or weighted > score then
        score = weighted
      end
    end
  end

  local genericScore = fuzzy(pattern, entry.genericLower)
  if genericScore ~= nil then
    local weighted = genericScore * 2
    if score == nil or weighted > score then
      score = weighted
    end
  end

  local keywordScore = scoreList(pattern, entry.keywordsList or {}, 0.8)
  if keywordScore ~= nil and (score == nil or keywordScore > score) then
    score = keywordScore
  end
  local categoryScore = scoreList(pattern, entry.categoriesList or {}, 0.3)
  if categoryScore ~= nil and (score == nil or categoryScore > score) then
    score = categoryScore
  end
  local idScore = fuzzy(pattern, entry.id:lower())
  if idScore ~= nil then
    local weighted = idScore * 1.5
    if score == nil or weighted > score then
      score = weighted
    end
  end
  local execScore = fuzzy(pattern, lower(entry.exec))
  if execScore ~= nil and (score == nil or execScore > score) then
    score = execScore
  end

  return score
end

local function usageBoost(score, count, typed)
  if count <= 0 then
    return 0
  end
  local raw = count * 0.1
  if not typed then
    return raw
  end
  if raw > 0.5 then
    raw = 0.5
  end
  return raw
end

local function appResult(entry, score)
  local subtitle = entry.generic
  if subtitle == nil or subtitle == "" then
    subtitle = entry.comment
  end
  return {
    provider = "Applications",
    id = entry.path,
    entry = entry,
    origin = entry.origin,
    title = entry.name,
    titleLower = entry.nameLower,
    subtitle = subtitle or "",
    iconName = entry.icon ~= "" and entry.icon or "application-x-executable",
    pinned = pinnedSet[entry.path] == true,
    rank = pinnedRank[entry.path],
    category = primaryCategory(entry.categories),
    score = score or 0,
  }
end

-- ── folders ─────────────────────────────────────────────────────────────────

local FOLDER_GLYPH = "folder"
local FOLDER_MEMBERS_SHOWN = 4

local function folderDisplayName(row)
  if type(row.name) == "string" and row.name ~= "" then
    return row.name
  end
  return T("folder.new", "New Folder")
end

local function folderResult(row)
  local name = folderDisplayName(row)
  return {
    provider = "Folder",
    id = row.id,
    folder = row,
    title = name,
    titleLower = lower(name),
    subtitle = T("folder.count", "{count} apps", { count = #(row.entries or {}) }),
    glyph = FOLDER_GLYPH,
    score = 0,
  }
end

-- The empty query renders the stored layout: folders and top-level apps in
-- store order. A typed query searches every application, folder member or not.
local function storedLayoutResults()
  local out = {}
  for _, row in ipairs(loadOrder().entries) do
    if row.type == "folder" then
      out[#out + 1] = folderResult(row)
    elseif row.type == "app" then
      local entry = findAppByPath(row.id)
      if entry ~= nil then
        out[#out + 1] = appResult(entry, 0)
      end
    end
  end
  return out
end

-- The folder subview shows its members with the same tiles as the main view.
local function buildFolderResults(row)
  local out = {}
  if type(row) ~= "table" or type(row.entries) ~= "table" then
    return out
  end
  for _, path in ipairs(row.entries) do
    local entry = findAppByPath(path)
    if entry ~= nil then
      local result = appResult(entry, 0)
      result.inFolder = row.id
      out[#out + 1] = result
    end
  end
  return out
end

local function queryApplications(pattern, typed)
  local list = {}
  local recent = recentIndex("Applications")
  local countCache = {}

  local function add(entry, baseScore)
    local count = usageCount("Applications", entry.path)
    local score = baseScore or 0
    if config.sortByUsage then
      score = score + usageBoost(score, count, typed)
    end
    local result = appResult(entry, score)
    result.recent = recent[entry.path] or 0
    result.usage = count
    list[#list + 1] = result
  end

  if pattern == "" then
    for _, entry in ipairs(apps or {}) do
      add(entry, 0)
    end
  else
    local needle = lower(pattern)
    for _, entry in ipairs(apps or {}) do
      local score = scoreApplication(entry, needle)
      if score ~= nil then
        add(entry, score)
      end
    end
  end

  if pattern == "" then
    -- The empty query follows the stored layout, so edits and pins stick.
    table.sort(list, function(a, b)
      local ar = orderRank[a.id] or math.huge
      local br = orderRank[b.id] or math.huge
      if ar ~= br then
        return ar < br
      end
      return a.titleLower < b.titleLower
    end)
  else
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end

  return list
end

local function emojiLabel(id)
  for _, category in ipairs(EMOJI_CATEGORIES) do
    if category.id == id then
      return category.label
    end
  end
  return "categories.all"
end

local function emojiResults(pattern, typed)
  local list = {}
  local recent = recentIndex("Emoji")

  local function add(entry, score)
    local count = usageCount("Emoji", "emoji-" .. entry.emoji)
    local base = score or 0
    if config.sortByUsage then
      base = base + usageBoost(base, count, typed)
    end
    local result = {
      provider = "Emoji",
      id = "emoji-" .. entry.emoji,
      title = entry.name,
      titleLower = entry.nameLower,
      subtitle = T(emojiLabel(entry.category), entry.category),
      emoji = entry.emoji,
      category = entry.category,
      score = base,
      recent = recent["emoji-" .. entry.emoji] or 0,
      usage = count,
    }
    list[#list + 1] = result
  end

  if pattern == "" then
    for _, entry in ipairs(getEmoji()) do
      add(entry, 0)
    end
    if config ~= nil and config.sortByUsage then
      table.sort(list, function(a, b)
        if a.score ~= b.score then
          return a.score > b.score
        end
      end)
    end
  else
    local needle = lower(pattern)
    for _, entry in ipairs(getEmoji()) do
      local best = nil
      if entry.nameLower == needle then
        best = 1000
      elseif startsWith(entry.nameLower, needle) then
        best = 500
      elseif entry.nameLower:find(needle, 1, true) ~= nil then
        best = 200
      else
        for _, keyword in ipairs(entry.keywords) do
          if keyword == needle then
            best = math.max(best or 0, 150)
          elseif startsWith(keyword, needle) then
            best = math.max(best or 0, 100)
          elseif keyword:find(needle, 1, true) ~= nil then
            best = math.max(best or 0, 50)
          end
        end
      end
      if best ~= nil then
        add(entry, best)
      end
    end
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end

  if #list > 120 then
    while #list > 120 do
      list[#list] = nil
    end
  end
  return list
end

local function wallpaperResults(pattern)
  local list = {}
  local recent = recentIndex("Wallpaper")
  local needle = lower(pattern)
  for _, item in ipairs(getWallpapers()) do
    local searchable = item.nameLower .. " " .. lower(item.dirName)
    local score = pattern == "" and 0 or fuzzy(needle, searchable)
    if score ~= nil then
      local count = usageCount("Wallpaper", item.path)
      local boosted = score
      if config.sortByUsage then
        boosted = boosted + usageBoost(score, count, pattern ~= "")
      end
      list[#list + 1] = {
        provider = "Wallpaper",
        id = item.path,
        path = item.path,
        title = item.name,
        titleLower = item.nameLower,
        subtitle = item.dirName,
        imagePath = item.path,
        score = boosted,
        recent = recent[item.path] or 0,
      }
    end
  end
  if pattern ~= "" then
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end
  if #list > 50 then
    while #list > 50 do
      list[#list] = nil
    end
  end
  return list
end

local function windowResults(pattern)
  local list = {}
  local needle = lower(pattern)
  for _, item in ipairs(windowState.list or {}) do
    local title = item.title or ""
    local searchable = lower(title .. " " .. item.appId)
    local score = pattern == "" and 0 or fuzzy(needle, searchable)
    if score ~= nil then
      local entry = nil
      for _, candidate in ipairs(apps or {}) do
        if candidate.id == item.appId or candidate.startupWmClass == item.appId then
          entry = candidate
          break
        end
      end
      list[#list + 1] = {
        provider = "Windows",
        id = item.id,
        title = title,
        titleLower = lower(title),
        subtitle = item.appId,
        iconName = entry and (entry.icon ~= "" and entry.icon or entry.id) or item.appId,
        glyph = "app-window",
        score = score,
      }
    end
  end
  if pattern ~= "" then
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end
  return list
end

local function sessionResults(pattern)
  local list = {}
  local needle = lower(pattern)
  local recent = recentIndex("Session")
  for _, item in ipairs(sessionActions()) do
    local score = pattern == "" and 0 or fuzzy(needle, item.searchable)
    if score ~= nil then
      list[#list + 1] = {
        provider = "Session",
        id = "session:" .. item.index .. ":" .. item.action,
        action = item.action,
        command = item.command,
        title = item.label,
        titleLower = lower(item.label),
        subtitle = item.command ~= "" and T("providers.session.command", "Custom command") or T("providers.session.action", "Session action"),
        glyph = item.glyph,
        score = score,
        recent = recent["session:" .. item.index .. ":" .. item.action] or 0,
      }
    end
  end
  if pattern ~= "" then
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end
  return list
end

local function overviewResults(filter)
  local list = {}
  local needle = lower(trim(filter))
  for _, id in ipairs(PROVIDER_ORDER) do
    local conf = config.providers[id]
    if conf.prefix ~= "" then
      local title = T("providers." .. id .. ".title", id)
      local searchable = lower(title .. " " .. conf.prefix)
      local score = needle == "" and 0 or fuzzy(needle, searchable)
      if score ~= nil then
        list[#list + 1] = {
          provider = "Overview",
          id = "provider:" .. id,
          target = id,
          title = title,
          titleLower = lower(title),
          subtitle = config.providerPrefix .. conf.prefix,
          glyph = PROVIDER_GLYPH[id] or "sparkles",
          score = score,
        }
      end
    end
  end
  if needle ~= "" then
    table.sort(list, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.titleLower < b.titleLower
    end)
  end
  return list
end

-- ── query routing ───────────────────────────────────────────────────────────

local function routeQuery()
  local text = query
  local prefix = config.providerPrefix
  if prefix ~= "" and startsWith(text, prefix) then
    local rest = text:sub(#prefix + 1)
    local active = nil
    for _, id in ipairs(PROVIDER_ORDER) do
      local trigger = config.providers[id].prefix
      if trigger ~= "" and startsWith(rest:lower(), trigger:lower()) then
        if active == nil or #trigger > #active.prefix then
          active = { id = id, prefix = trigger }
        end
      end
    end
    if active ~= nil then
      local base = rest:sub(#active.prefix + 1)
      if base:sub(1, 1) == " " then
        base = base:sub(2)
      end
      return PROVIDER_CANONICAL[active.id] or active.id, base
    end
    return "Overview", rest
  end
  return "Applications", text
end

local function filterByCategory(list)
  if catFilter == "all" or catFilter == nil then
    return list
  end
  local out = {}
  for _, result in ipairs(list) do
    if catFilter == "recent" then
      if (result.recent or 0) > 0 and result.provider ~= "Calculator" then
        out[#out + 1] = result
      end
    elseif result.category == catFilter then
      out[#out + 1] = result
    end
  end
  if catFilter == "recent" then
    table.sort(out, function(a, b)
      if (a.recent or 0) ~= (b.recent or 0) then
        return (a.recent or 0) > (b.recent or 0)
      end
      return (a.titleLower or "") < (b.titleLower or "")
    end)
  end
  return out
end

local function applyCategoryFilter(list)
  return filterByCategory(list)
end

local function trimResults(list, limit)
  if #list > limit then
    while #list > limit do
      list[#list] = nil
    end
  end
  return list
end

local function maybeCalculate()
  local expression = nil
  if providerId == "Calculator" then
    expression = trim(providerQuery)
  elseif providerId == "Applications" and query:find("%d") ~= nil then
    expression = trim(query)
  end

  if expression == nil or expression == "" then
    calc.result = nil
    calc.expression = nil
    calc.pending = false
    return
  end
  if calc.expression == expression then
    return
  end

  calc.expression = expression
  calc.result = nil
  calc.pending = true
  local seq = calc.seq + 1
  calc.seq = seq

  if not noctalia.commandExists("qalc") then
    calc.pending = false
    return
  end

  noctalia.runAsync({ "qalc", "-t", expression }, function(result)
    if seq ~= calc.seq then
      return
    end
    calc.pending = false
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local output = trim(result.stdout or "")
    if output == "" then
      return
    end
    if lower(output):find("error", 1, true) ~= nil then
      return
    end
    local firstLine = output:match("([^\n]+)") or output
    firstLine = trim(firstLine)
    if firstLine == "" or firstLine == expression then
      return
    end
    calc.result = {
      provider = "Calculator",
      id = "calc:" .. expression,
      title = firstLine,
      titleLower = lower(firstLine),
      subtitle = expression,
      glyph = "calculator",
      score = 1000000,
      expression = expression,
    }
    if isOpen then
      refresh()
      render()
    end
  end)
end

local function buildResults()
  forceList = false
  local list = {}

  if providerId == "Applications" then
    -- The empty query is the app drawer: the stored layout with folders. A
    -- typed query searches every application and stays capped so a very broad
    -- match does not build a huge tree.
    if providerQuery == "" then
      list = storedLayoutResults()
      list = applyCategoryFilter(list)
    else
      list = queryApplications(providerQuery, true)
      list = applyCategoryFilter(list)
      list = trimResults(list, 50)
    end

    if providerQuery ~= "" then
      for _, id in ipairs(PROVIDER_ORDER) do
        if id ~= "calculator" and config.providers[id].global and #trim(providerQuery) >= 2 then
          local extra = nil
          if id == "emoji" then
            extra = emojiResults(providerQuery, true)
          elseif id == "wallpaper" then
            extra = wallpaperResults(providerQuery)
          elseif id == "session" then
            extra = sessionResults(providerQuery)
          elseif id == "windows" then
            extra = windowResults(providerQuery)
          end
          if extra ~= nil then
            for _, item in ipairs(extra) do
              if catFilter == "all" then
                list[#list + 1] = item
              end
            end
          end
        end
      end
      table.sort(list, function(a, b)
        if catFilter == "recent" then
          if (a.recent or 0) ~= (b.recent or 0) then
            return (a.recent or 0) > (b.recent or 0)
          end
        end
        if a.score ~= b.score then
          return a.score > b.score
        end
        return (a.titleLower or "") < (b.titleLower or "")
      end)
    end

    maybeCalculate()
    if calc.result ~= nil then
      table.insert(list, 1, calc.result)
      forceList = true
    end
    for _, item in ipairs(list) do
      if item.provider == "Windows" then
        forceList = true
        break
      end
    end
  elseif providerId == "Calculator" then
    maybeCalculate()
    if calc.result ~= nil then
      list = { calc.result }
    end
    forceList = true
  elseif providerId == "Emoji" then
    list = emojiResults(providerQuery, providerQuery ~= "")
    list = applyCategoryFilter(list)
  elseif providerId == "Wallpaper" then
    list = wallpaperResults(providerQuery)
  elseif providerId == "Session" then
    list = sessionResults(providerQuery)
  elseif providerId == "Windows" then
    refreshWindows(false)
    list = windowResults(providerQuery)
    forceList = true
  elseif providerId == "Overview" then
    list = overviewResults(providerQuery)
  end

  return list
end

local function providerCategories()
  if providerId == "Applications" then
    if not config.categories then
      return {}
    end
    local out = { { id = "all", glyph = "layout-grid", label = T("categories.all", "All") } }
    local recent = recentList("Applications")
    if #recent > 0 then
      out[#out + 1] = { id = "recent", glyph = "history", label = T("categories.recent", "Recently used") }
    end
    for _, category in ipairs(buildAppCategories()) do
      out[#out + 1] = { id = category.id, glyph = category.glyph, label = T(category.label, category.id) }
    end
    return out
  elseif providerId == "Emoji" then
    local out = { { id = "all", glyph = "layout-grid", label = T("categories.all", "All") } }
    if #recentList("Emoji") > 0 then
      out[#out + 1] = { id = "recent", glyph = "history", label = T("categories.recent", "Recently used") }
    end
    for _, category in ipairs(EMOJI_CATEGORIES) do
      out[#out + 1] = { id = category.id, glyph = category.glyph, label = T(category.label, category.id) }
    end
    return out
  end
  return {}
end

refresh = function()
  local newProvider, base = routeQuery()
  local providerChanged = newProvider ~= providerId
  providerId = newProvider
  providerQuery = base
  if providerChanged then
    catFilter = "all"
    selected = 1
    scrollRev = scrollRev + 1
  end

  categories = providerCategories()
  if catFilter ~= "all" then
    local found = false
    for _, category in ipairs(categories) do
      if category.id == catFilter then
        found = true
        break
      end
    end
    if not found then
      catFilter = "all"
    end
  end

  results = buildResults()
  if #results == 0 then
    selected = 1
  elseif selected < 1 then
    selected = 1
  elseif selected > #results then
    selected = #results
  end
  resultsShown = RESULTS_PER_FRAME
  flags.more = false
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function isGrid()
  if not config.appGrid or not config.showIcons or forceList then
    return false
  end
  return providerId == "Applications" or providerId == "Emoji"
    or providerId == "Wallpaper" or providerId == "Session" or providerId == "Overview"
end

-- Icon-theme lookups are the expensive part of a grid render, and they stack
-- with the tree rebuild when they run inside it. Render with cached paths and
-- glyph fallbacks only; queued names are resolved during frame ticks within a
-- small time budget, and a frame either looks icons up or rebuilds the tree.
-- Resolved paths persist in the plugin data directory, so reopening the panel
-- draws every icon immediately.
local ICON_CACHE_VERSION = 1
local ICON_LOOKUP_BUDGET_MS = 10
-- Swapping an image path makes the host rebuild that image control, so the
-- resolved set is drawn in small groups to keep each frame light.
local ICONS_PER_TICK = 12
local iconQueue = {}
local iconQueued = {}
local iconStore = { loaded = false, dirty = false }

local function iconCacheFile()
  local dataDir = noctalia.pluginDataDir()
  if type(dataDir) ~= "string" or dataDir == "" then
    return nil
  end
  return dataDir .. "/icon-cache.json"
end

local function loadIconCache()
  if iconStore.loaded then
    return
  end
  iconStore.loaded = true
  local path = iconCacheFile()
  local stored = path ~= nil and readJson(path) or nil
  if type(stored) ~= "table" or stored.version ~= ICON_CACHE_VERSION or type(stored.icons) ~= "table" then
    return
  end
  for key, value in pairs(stored.icons) do
    -- A theme switch or uninstall leaves dead paths behind; drop them here.
    if type(value) == "string" and value ~= "" and noctalia.fileExists(value) then
      iconCache[key] = value
    end
  end
end

local function saveIconCache()
  local path = iconCacheFile()
  if path == nil then
    return
  end
  local icons = {}
  for key, value in pairs(iconCache) do
    if type(value) == "string" then
      icons[key] = value
    end
  end
  writeJson(path, { version = ICON_CACHE_VERSION, icons = icons })
end

local function queueIcon(name, size)
  if type(name) ~= "string" or name == "" or type(size) ~= "number" then
    return
  end
  -- The layout editor redraws every stored tile on each change; a lookup queue
  -- there would re-render the whole grid per icon batch. Cached paths and the
  -- glyph fallback are enough, and entering the editor from the grid has
  -- already warmed the cache for every visible app.
  if mode == "edit" then
    return
  end
  local key = name .. "@" .. tostring(size)
  if iconCache[key] ~= nil or iconQueued[key] then
    return
  end
  iconQueued[key] = true
  iconQueue[#iconQueue + 1] = { key = key, name = name, size = size }
end

local function resolveIcon(name, size)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local key = name .. "@" .. tostring(size)
  local cached = iconCache[key]
  if cached == nil then
    queueIcon(name, size)
    return nil
  end
  if cached == false then
    return nil
  end
  return cached
end

local function iconNode(result, width, height)
  if result.emoji ~= nil then
    return ui.label({
      text = result.emoji,
      fontSize = math.floor(height * 0.72),
      width = width,
      height = height,
      textAlign = "center",
      baseline = "pictographic",
    })
  end
  if result.imagePath ~= nil then
    return ui.image({
      path = result.imagePath,
      width = width,
      height = height,
      radius = 6,
      fit = "cover",
      border = "outline_variant",
      borderWidth = 1,
    })
  end
  local path = resolveIcon(result.iconName, height)
  if path ~= nil then
    return ui.image({ path = path, width = width, height = height, fit = "contain" })
  end
  return ui.glyph({ name = result.glyph or "app-window", size = math.floor(height * 0.7), color = "on_surface_variant" })
end

-- The shell marks Flatpak/Snap and AppImage entries with a small glyph; other
-- origins stay unmarked.
local ORIGIN_GLYPHS = {
  Flatpak = "package",
  Snap = "package",
  AppImage = "settings-automation",
}

local ORIGIN_LABELS = {
  Flatpak = { "origin.flatpak", "Flatpak" },
  Snap = { "origin.snap", "Snap" },
  AppImage = { "origin.appimage", "AppImage" },
}

local function originLabel(origin)
  local label = ORIGIN_LABELS[origin]
  if label == nil then
    return nil
  end
  return T(label[1], label[2])
end

local function originBadge(origin, size)
  local glyph = ORIGIN_GLYPHS[origin]
  if glyph == nil then
    return nil
  end
  return ui.row({
    width = size,
    height = size,
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = glyph, size = size, color = "on_surface_variant" }),
  })
end

-- The folder subview reuses the result tiles, so its overlays report the same
-- ov-N keys as the main grid. The scope keeps a hover in one list from lighting
-- the same index in the other (the scrim would show the card underneath).
local function isFocused(index, inFolder)
  if hoverIndex ~= nil then
    return (hoverFolder == true) == (inFolder == true) and hoverIndex == index
  end
  return keyboardFocus and inFolder ~= true and selected == index
end

local TILE_HEIGHT = 108
local ROW_HEIGHT = 54

-- Right-click handling. Only a button receives right-clicks in a panel, so each
-- card carries a transparent button stretched over the whole tile with the
-- compositing `translateY` offset; the card itself stays purely visual.
-- The first right-click opens the native menu, a second one on the same app
-- inside RIGHT_CLICK_WINDOW enters edit mode.
local function requestEditMode(index)
  if mode == "edit" then
    return false
  end
  local now = os.time()
  if lastRight.index == index and now - lastRight.at <= RIGHT_CLICK_WINDOW then
    lastRight.index = nil
    enterEditMode()
    return true
  end
  lastRight.index = index
  lastRight.at = now
  return false
end

local function resultOverlay(result, index, height, list)
  return ui.button({
    key = "ov-" .. index,
    height = height,
    translateY = -height,
    opacity = 0,
    variant = "ghost",
    tooltip = originLabel(result.origin),
    onClick = function() activate(index, list) end,
    onRightClick = function()
      if requestEditMode(index) then
        return
      end
      openResultMenu(index, list)
    end,
    onHover = "onResultHover",
  })
end

-- Fixed-height bands keep the icon in the same place whether the name wraps
-- to one line or two: the label is measured by its text, so it lives inside a
-- 30px row that clips instead of stretching the column.
local TILE_BADGE_BAND = 12
local TILE_ICON_BAND = 42
local TILE_NAME_BAND = 34
local TILE_ORIGIN_BAND = 12

-- Folder tiles show up to four member icons in a 2x2 grid; missing members
-- get empty placeholders so the tile always has the same shape.
local function folderMiniIcon(path)
  local entry = path ~= nil and findAppByPath(path) or nil
  if entry == nil then
    return ui.box({ width = 19, height = 19, radius = 4, fill = "surface_container_high" })
  end
  local name = entry.icon ~= "" and entry.icon or "application-x-executable"
  local iconPath = resolveIcon(name, 19)
  if iconPath ~= nil then
    return ui.image({ path = iconPath, width = 19, height = 19, fit = "contain" })
  end
  return ui.glyph({ name = "app-window", size = 13, color = "on_surface_variant" })
end

local function folderIconGrid(row)
  local members = {}
  for position = 1, FOLDER_MEMBERS_SHOWN do
    members[#members + 1] = folderMiniIcon((row.entries or {})[position])
  end
  return ui.column({ gap = 2, align = "center" }, {
    ui.row({ gap = 2 }, { members[1], members[2] }),
    ui.row({ gap = 2 }, { members[3], members[4] }),
  })
end

local function folderCard(result, focused, key)
  local row = result.folder
  local count = #(row.entries or {})
  local children = {
    ui.row({ height = TILE_BADGE_BAND, justify = "end", align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.row({ height = TILE_ICON_BAND, justify = "center", align = "center" }, {
      folderIconGrid(row),
    }),
    ui.column({ height = TILE_NAME_BAND, align = "center", justify = "start", clip = true }, {
      ui.label({
        text = result.title,
        fontSize = 11,
        maxLines = 2,
        textAlign = "center",
        color = focused and "on_surface" or "on_surface_variant",
      }),
    }),
    ui.row({ height = TILE_ORIGIN_BAND, justify = "end", align = "center" }, {
      ui.label({ text = tostring(count), fontSize = 10, color = "on_surface_variant" }),
    }),
  }
  return ui.column({
    key = key,
    height = TILE_HEIGHT,
    gap = 0,
    padding = 4,
    align = "stretch",
    justify = "start",
    radius = 10,
    fill = focused and "primary/0.16" or "surface/0",
  }, children)
end

local function folderTile(result, index, list)
  return ui.column({
    key = "res-" .. index,
    flexGrow = 1,
    height = TILE_HEIGHT,
    gap = 0,
    align = "stretch",
  }, {
    folderCard(result, isFocused(index, list == folderResults), "card-" .. index),
    resultOverlay(result, index, TILE_HEIGHT, list),
  })
end

local function folderListRow(result, index, list)
  return ui.column({ key = "res-" .. index, height = ROW_HEIGHT, gap = 0, align = "stretch" }, {
    listCard(result, isFocused(index, list == folderResults), "card-" .. index),
    resultOverlay(result, index, ROW_HEIGHT, list),
  })
end

local function tileCard(result, focused, key, pinned, grow)
  local iconWidth, iconHeight = 40, 40
  if result.imagePath ~= nil then
    iconWidth, iconHeight = 74, 40
  end

  local pinBadge = nil
  if pinned then
    pinBadge = ui.row({ width = 12, height = 12, align = "center", justify = "center" }, {
      ui.glyph({ name = "pin-filled", size = 11, color = "primary" }),
    })
  end
  local badge = originBadge(result.origin, 12)

  local children = {
    ui.row({ height = TILE_BADGE_BAND, justify = "end", align = "center" }, {
      pinBadge or ui.spacer({ flexGrow = 1 }),
    }),
    ui.row({ height = TILE_ICON_BAND, justify = "center", align = "center" }, {
      iconNode(result, iconWidth, iconHeight),
    }),
    ui.column({ height = TILE_NAME_BAND, align = "center", justify = "start", clip = true }, {
      ui.label({
        text = result.title,
        fontSize = 11,
        maxLines = 2,
        textAlign = "center",
        color = focused and "on_surface" or "on_surface_variant",
      }),
    }),
    ui.row({ height = TILE_ORIGIN_BAND, justify = "end", align = "center" }, {
      badge or ui.spacer({ flexGrow = 1 }),
    }),
  }
  return ui.column({
    key = key,
    height = TILE_HEIGHT,
    gap = 0,
    padding = 4,
    align = "stretch",
    justify = "start",
    radius = 10,
    fill = focused and "primary/0.16" or "surface/0",
    flexGrow = grow == true and 1 or nil,
  }, children)
end

local function tile(result, index, list)
  if result.provider == "Folder" then
    return folderTile(result, index, list)
  end
  return ui.column({
    key = "res-" .. index,
    flexGrow = 1,
    height = TILE_HEIGHT,
    gap = 0,
    align = "stretch",
  }, {
    tileCard(result, isFocused(index, list == folderResults), "card-" .. index, result.pinned),
    resultOverlay(result, index, TILE_HEIGHT, list),
  })
end

local function listCard(result, focused, key)
  local text = ui.column({ gap = 1, flexGrow = 1, align = "start" }, {
    ui.label({
      text = result.title,
      fontSize = 14,
      fontWeight = "semibold",
      maxLines = 1,
      color = "on_surface",
    }),
    ui.label({
      text = result.subtitle or "",
      fontSize = 11,
      maxLines = 1,
      color = "on_surface_variant",
    }),
  })
  local children = { iconNode(result, 32, 32), text }
  local badge = originBadge(result.origin, 14)
  if badge ~= nil then
    children[#children + 1] = badge
  end
  if result.pinned then
    children[#children + 1] = ui.glyph({ name = "pin-filled", size = 14, color = "primary" })
  elseif result.provider == "Calculator" then
    children[#children + 1] = ui.glyph({ name = "copy", size = 14, color = "on_surface_variant" })
  end
  return ui.row({
    key = key,
    height = ROW_HEIGHT,
    gap = 12,
    paddingH = 10,
    paddingV = 6,
    align = "center",
    radius = 10,
    fill = focused and "primary/0.16" or "surface/0",
  }, children)
end

local function listRow(result, index, list)
  if result.provider == "Folder" then
    return folderListRow(result, index, list)
  end
  return ui.column({ key = "res-" .. index, height = ROW_HEIGHT, gap = 0, align = "stretch" }, {
    listCard(result, isFocused(index, list == folderResults), "card-" .. index),
    resultOverlay(result, index, ROW_HEIGHT, list),
  })
end

local function resultNodes()
  return resultNodesFrom(results, nil)
end

-- `list` is the tile model the overlay closures resolve against: the main
-- results, or the open folder's members.
resultNodesFrom = function(list, keyPrefix)
  local nodes = {}
  local count = math.min(resultsShown, #list)
  flags.more = count < #list
  if isGrid() then
    local row = {}
    for index = 1, count do
      row[#row + 1] = tile(list[index], index, list)
      if #row == 5 then
        nodes[#nodes + 1] = ui.row({ gap = 8, align = "stretch" }, row)
        row = {}
      end
    end
    if #row > 0 then
      while #row < 5 do
        row[#row + 1] = ui.spacer({ flexGrow = 1 })
      end
      nodes[#nodes + 1] = ui.row({ gap = 8, align = "stretch" }, row)
    end
  else
    for index = 1, count do
      nodes[#nodes + 1] = listRow(list[index], index, list)
    end
  end
  return nodes
end

local function placeholder()
  if providerId == "Emoji" then
    return T("search.emoji", "Search emoji…")
  elseif providerId == "Wallpaper" then
    return T("search.wallpaper", "Search wallpapers…")
  elseif providerId == "Session" then
    return T("search.session", "Search session actions…")
  elseif providerId == "Windows" then
    return T("search.windows", "Search open windows…")
  elseif providerId == "Calculator" then
    return T("search.calculator", "Type an expression…")
  elseif providerId == "Overview" then
    return T("search.providers", "Search providers…")
  end
  return T("search.placeholder", "Search applications…")
end

local function emptyState()
  local title = T("empty.title", "No results")
  local body = T("empty.body", "Try a different search.")
  if providerId == "Calculator" then
    title = T("calculator.empty.title", "Calculate")
    body = T("calculator.empty.body", "Type an expression, then press Enter to copy the result.")
  elseif providerId == "Emoji" then
    body = T("empty.emoji", "Try an emoji name or keyword.")
  elseif providerId == "Wallpaper" then
    body = T("empty.wallpaper", "No wallpapers were found in your wallpaper directory.")
  elseif providerId == "Windows" then
    body = T("empty.windows", "No open windows were reported by the compositor.")
  elseif providerId == "Overview" then
    body = T("empty.providers", "Type a provider name or prefix.")
  elseif calc.pending then
    body = T("calculator.pending", "Calculating…")
  end
  return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = "search-off", size = 28, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = body, fontSize = 12, color = "on_surface_variant", textAlign = "center", maxWidth = 320 }),
  })
end

-- ── edit mode ───────────────────────────────────────────────────────────────

-- Edit mode is a separate surface: no search field, no provider routing, just
-- the stored layout in five-column form. Rows are drag sources dropped onto
-- neighbouring tiles; folders and other row types will slot in here later.
local DRAG_TYPE = "better-launchpad-app"
local EDIT_MODES = { "swap", "folder" }

-- The plugin API cannot read modifier state (a drag source only ever arms on
-- the left button, and capture_keys would have to consume Shift globally), so
-- the "hold a modifier to fold instead of swap" gesture becomes an explicit
-- drag mode in the editor header.
local function editHeader()
  local function modeButton(id, label, glyph)
    return ui.button({
      key = "emode-" .. id,
      text = label,
      glyph = glyph,
      fontSize = 11,
      glyphSize = 14,
      variant = "ghost",
      selected = editDragMode == id,
      height = 28,
      onClick = function()
        if editDragMode == id then
          return
        end
        editDragMode = id
        flags.render = true
        panel.setNeedsFrameTick(true)
      end,
    })
  end
  local hint = editDragMode == "folder"
      and T("edit.hint_folder", "Drag an app onto another app to make a folder")
      or T("edit.hint", "Drag a tile onto another to reorder")
  -- Two rows: the title shares its row only with the short "Done" button, so a
  -- long localized hint can never push that button out of the visible header.
  return ui.column({
    gap = 4,
    paddingH = 12,
    paddingV = 8,
    fill = "surface_container",
    radius = 12,
    border = "outline_variant",
    borderWidth = 1,
  }, {
    ui.row({ height = 30, gap = 8, align = "center" }, {
      ui.glyph({ name = "layout-grid", size = 18, color = "primary" }),
      ui.label({
        text = T("edit.title", "Edit layout"),
        fontSize = 14,
        fontWeight = "semibold",
        color = "on_surface",
        maxLines = 1,
        flexGrow = 1,
      }),
      ui.button({
        key = "edit-done",
        text = T("edit.done", "Done"),
        variant = "secondary",
        controlSize = "sm",
        onClick = function() exitEditMode() end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = hint,
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
        maxWidth = 330,
        flexGrow = 1,
      }),
      ui.row({
        gap = 2,
        padding = 2,
        align = "center",
        fill = "surface_container_high",
        radius = 9,
      }, {
        modeButton("swap", T("edit.mode_swap", "Swap"), "arrows-move"),
        modeButton("folder", T("edit.mode_folder", "Folder"), FOLDER_GLYPH),
      }),
    }),
  })
end

local function editTile(row, position)
  local card = nil
  if row.type == "folder" then
    card = folderCard(folderResult(row), false, "ecard-" .. position)
  else
    local entry = findAppByPath(row.id)
    if entry == nil then
      return nil
    end
    local result = {
      provider = "Applications",
      title = entry.name,
      iconName = entry.icon ~= "" and entry.icon or "application-x-executable",
      origin = entry.origin,
      pinned = row.pinned == true,
    }
    -- The drag source is a horizontal flex, so the card needs flexGrow to fill
    -- the cell; without it the tile hugs its content and the name never wraps.
    card = tileCard(result, false, "ecard-" .. position, row.pinned == true, true)
  end
  -- The wrappers stay invisible: only the card paints, so an editor tile looks
  -- exactly like a normal one. The zone is a column so the source stretches
  -- across the cell, and the source grows so the card fills it.
  return ui.dropZone({
    key = "ezone-" .. position,
    height = TILE_HEIGHT,
    flexGrow = 1,
    direction = "column",
    align = "stretch",
    accepts = { DRAG_TYPE },
    value = tostring(position),
    onDrop = "onReorderDrop",
  }, {
    ui.dragSource({
      dragType = DRAG_TYPE,
      payload = row.id,
      previewAncestor = 0,
      height = TILE_HEIGHT,
      flexGrow = 1,
      align = "stretch",
    }, { card }),
  })
end

-- Building every editor tile in one callback costs more than the 25 ms budget
-- (64 rows x wrapper + card > 1000 nodes) and the host disables a panel that
-- times out repeatedly, so the grid grows in chunks like the result grid does.
local function editNodes()
  local nodes = {}
  local row = {}
  local shown = 0
  local total = 0
  for position, entry in ipairs(loadOrder().entries) do
    if entry.type == "folder" or entry.type == "app" then
      total = total + 1
      if shown < editShown then
        -- Count the attempt, not the node: an app whose desktop entry vanished
        -- renders nothing, and the counter must still advance or the chunked
        -- grid would schedule frames forever.
        shown = shown + 1
        local node = editTile(entry, position)
        if node ~= nil then
          row[#row + 1] = node
          if #row == 5 then
            nodes[#nodes + 1] = ui.row({ gap = 8, align = "stretch" }, row)
            row = {}
          end
        end
      end
    end
  end
  if #row > 0 then
    while #row < 5 do
      row[#row + 1] = ui.spacer({ flexGrow = 1 })
    end
    nodes[#nodes + 1] = ui.row({ gap = 8, align = "stretch" }, row)
  end
  flags.more = shown < total
  return nodes
end

local function renderEdit()
  local nodes = editNodes()
  local body = nil
  if #nodes == 0 then
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "apps", size = 28, color = "on_surface_variant" }),
      ui.label({
        text = T("edit.empty", "No applications to arrange yet."),
        fontSize = 12,
        color = "on_surface_variant",
      }),
    })
  else
    body = ui.scroll({ key = "edit-" .. scrollRev, flexGrow = 1, gap = 6 }, nodes)
  end
  return ui.column({ flexGrow = 1, gap = 10 }, { editHeader(), body })
end

openFolder = function(row)
  if type(row) ~= "table" or mode ~= "normal" then
    return
  end
  folderOpen = row
  folderResults = buildFolderResults(row)
  hoverIndex = nil
  hoverFolder = false
  keyboardFocus = false
  selected = 1
  inputRev = inputRev + 1
  render()
end

closeFolder = function()
  if folderOpen == nil then
    return
  end
  folderOpen = nil
  folderResults = {}
  hoverIndex = nil
  hoverFolder = false
  keyboardFocus = true
  inputRev = inputRev + 1
  render()
end

enterEditMode = function()
  if mode == "edit" or not isOpen then
    return
  end
  closeFolder()
  mode = "edit"
  editDragMode = "swap"
  editShown = RESULTS_PER_FRAME
  hoverIndex = nil
  keyboardFocus = true
  lastRight.index = nil
  scrollRev = scrollRev + 1
  render()
end

exitEditMode = function()
  if mode ~= "edit" then
    return
  end
  mode = "normal"
  hoverIndex = nil
  keyboardFocus = true
  selected = 1
  scrollRev = scrollRev + 1
  focusInput()
  refresh()
  render()
end

function onReorderDrop(payload, value)
  if mode ~= "edit" then
    return
  end
  local target = tonumber(value)
  local store = loadOrder()
  local row = target ~= nil and store.entries[target] or nil
  local from = orderRowIndex(payload)
  if row == nil or from == nil or from == target then
    return
  end
  local dragged = store.entries[from]
  if editDragMode == "folder" then
    -- Folders never nest: only an application can be folded, and the target is
    -- either another application (a new folder) or an existing folder.
    if dragged.type ~= "app" then
      return
    end
    if row.type == "folder" then
      addToFolder(row.id, payload)
    elseif row.type == "app" then
      createFolderWithApps({ row.id, payload }, nil, row.id)
    end
    -- The drop callback shares the 25 ms budget with the store write, so the
    -- grid rebuild waits for the next frame tick instead of running here.
    flags.render = true
    panel.setNeedsFrameTick(true)
    return
  end
  -- Swap mode: reordering, but dropping an application on a folder folds it in.
  if row.type == "folder" and dragged.type == "app" then
    addToFolder(row.id, payload)
    flags.render = true
    panel.setNeedsFrameTick(true)
    return
  end
  moveOrderRow(payload, value)
  flags.render = true
  panel.setNeedsFrameTick(true)
end

-- The folder subview floats over a scrim that covers the whole panel,
-- including the search bar. The root gets the panel's exact height so the
-- mask can composite over it; clicks outside the subview land on the mask.
local PANEL_HEIGHT = 500

local function folderMask()
  local body = nil
  if #folderResults == 0 then
    body = ui.label({
      text = T("folder.empty", "This folder is empty."),
      fontSize = 12,
      color = "on_surface_variant",
      textAlign = "center",
    })
  else
    body = ui.scroll({
      key = "folder-scroll-" .. (folderOpen.id or ""),
      flexGrow = 1,
      gap = 6,
    }, resultNodesFrom(folderResults))
  end
  local subview = ui.column({
    key = "folder-subview",
    width = 420,
    height = 360,
    fill = "surface_container_high",
    radius = 14,
    border = "outline_variant",
    borderWidth = 1,
    clip = true,
    onClick = function() end,
  }, {
    ui.row({ height = 44, paddingH = 12, gap = 8, align = "center" }, {
      ui.glyph({ name = FOLDER_GLYPH, size = 18, color = "primary" }),
      ui.label({
        text = folderDisplayName(folderOpen),
        fontSize = 14,
        fontWeight = "semibold",
        color = "on_surface",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        text = T("folder.count", "{count} apps", { count = #folderResults }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        onClick = function() closeFolder() end,
        tooltip = T("folder.close", "Close"),
      }),
    }),
    body,
  })
  return ui.column({
    key = "folder-mask",
    height = PANEL_HEIGHT,
    translateY = -PANEL_HEIGHT,
    fill = "scrim/0.55",
    align = "center",
    justify = "center",
    clip = true,
    onClick = function() closeFolder() end,
  }, { subview })
end

function render()
  if not isOpen then
    return
  end

  flags.more = false

  local root = nil
  if mode == "edit" then
    root = renderEdit()
  else
    root = renderNormal()
  end
  if folderOpen ~= nil and mode == "normal" then
    -- The content keeps the panel's height so the mask, which sits one panel
    -- height below it, composites exactly over the whole panel after its
    -- translateY. The wrapper clips the overflow, so the measured height stays
    -- at PANEL_HEIGHT.
    root = ui.column({ key = "panel-root", height = PANEL_HEIGHT, gap = 0, clip = true }, {
      ui.column({ height = PANEL_HEIGHT, gap = 10 }, { root }),
      folderMask(),
    })
  end
  panel.render(root)
  if #iconQueue > 0 or flags.more or flags.icons then
    panel.setNeedsFrameTick(true)
  end
end

renderNormal = function()
  local header = ui.row({
    height = 46,
    gap = 8,
    paddingH = 12,
    align = "center",
    fill = "surface_container",
    radius = 12,
    border = "outline_variant",
    borderWidth = 1,
  }, {
    ui.glyph({ name = "search", size = 18, color = "on_surface_variant" }),
    ui.input({
      key = "query-" .. inputRev,
      value = query,
      placeholder = placeholder(),
      fontSize = 15,
      flexGrow = 1,
      frameVisible = false,
      focus = folderOpen == nil,
      onChange = "onQueryChanged",
      onSubmit = "onSubmit",
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      visible = query ~= "",
      onClick = "clearQuery",
      tooltip = T("search.clear", "Clear"),
    }),
  })

  local root = { header }

  if #categories > 0 then
    local chips = {}
    for _, category in ipairs(categories) do
      chips[#chips + 1] = ui.button({
        key = "cat-" .. category.id,
        glyph = category.glyph,
        variant = catFilter == category.id and "secondary" or "ghost",
        selected = catFilter == category.id,
        tooltip = category.label,
        onClick = function() setCategory(category.id) end,
      })
    end
    root[#root + 1] = ui.row({ gap = 4, align = "center" }, chips)
  end

  local body = nil
  if #results == 0 then
    body = emptyState()
  else
    body = ui.scroll({
      key = "results-" .. scrollRev,
      flexGrow = 1,
      gap = 6,
      revealKey = "res-" .. selected,
    }, resultNodes())
  end
  root[#root + 1] = body

  return ui.column({ flexGrow = 1, gap = 10 }, root)
end

-- ── activation ──────────────────────────────────────────────────────────────

focusInput = function()
  inputRev = inputRev + 1
end

function setQuery(value)
  query = value or ""
  selected = 1
  hoverIndex = nil
  keyboardFocus = true
  scrollRev = scrollRev + 1
  focusInput()
  refresh()
  render()
end

function setCategory(id)
  catFilter = id
  selected = 1
  hoverIndex = nil
  keyboardFocus = true
  scrollRev = scrollRev + 1
  focusInput()
  refresh()
  render()
end

function clearQuery()
  setQuery("")
end

function onQueryChanged(value)
  if value == query then
    return
  end
  query = value
  selected = 1
  hoverIndex = nil
  keyboardFocus = true
  scrollRev = scrollRev + 1
  refresh()
  render()
end

local function copyText(text)
  local ok = noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  if not ok then
    ok = noctalia.copyToClipboard(text, "text/plain")
  end
  return ok
end

local function finish()
  panel.close()
  isOpen = false
end

local function activateSession(result)
  recordUsage("Session", result.id)
  local command = result.command
  if type(command) == "string" and command ~= "" then
    noctalia.runAsync(command)
  else
    noctalia.runAsync({ "noctalia", "msg", "session", result.action })
  end
  finish()
end

function activate(index, list)
  local result = (list or results)[index]
  if result == nil then
    return
  end

  if result.provider == "Folder" then
    openFolder(result.folder)
    return
  end

  if result.provider == "Overview" then
    setQuery(config.providerPrefix .. config.providers[result.target].prefix .. " ")
    return
  end

  if result.provider == "Applications" then
    launchApplication(result.entry)
    finish()
  elseif result.provider == "Calculator" then
    if not copyText(result.title) then
      noctalia.notifyError(T("title", "Better Launchpad"), T("copy.failed", "Could not copy the result."))
    end
    finish()
  elseif result.provider == "Emoji" then
    recordUsage("Emoji", result.id)
    if not copyText(result.emoji) then
      noctalia.notifyError(T("title", "Better Launchpad"), T("copy.failed", "Could not copy the result."))
    end
    finish()
  elseif result.provider == "Wallpaper" then
    recordUsage("Wallpaper", result.path)
    noctalia.setWallpaper(result.path)
    finish()
  elseif result.provider == "Session" then
    activateSession(result)
  elseif result.provider == "Windows" then
    recordUsage("Windows", result.id)
    local ok = false
    if noctalia.umbriel ~= nil and noctalia.umbriel.action ~= nil then
      ok = noctalia.umbriel.action({ action = "window-focus", window = result.id }, function(success)
        if not success and isOpen then
          noctalia.runAsync({ "umbriel", "msg", "window-focus", result.id })
        end
      end)
    end
    if not ok then
      noctalia.runAsync({ "umbriel", "msg", "window-focus", result.id })
    end
    finish()
  end
end

-- ── context menu ────────────────────────────────────────────────────────────

local MENU_MAX_VISIBLE = 14

-- Desktop actions carry a launchable Exec and a label; anything else the
-- scanner dropped already, but re-check so a bad row never opens a dead entry.
local function launchableActions(entry)
  local out = {}
  if type(entry) ~= "table" or type(entry.actions) ~= "table" then
    return out
  end
  for position, action in ipairs(entry.actions) do
    if type(action) == "table"
      and type(action.name) == "string" and action.name ~= ""
      and type(action.exec) == "string" and action.exec ~= "" then
      out[#out + 1] = { position = position, name = action.name, exec = action.exec }
    end
  end
  return out
end

-- Mirrors the built-in menu: Open, the desktop actions, then pin/unpin. The
-- layout editor is reachable from here as well as from a double right-click.
openResultMenu = function(index, list)
  local result = (list or results)[index]
  if result == nil or panel.openContextMenu == nil then
    return false
  end
  local items = { { kind = "header", label = result.title } }
  items[#items + 1] = { id = "open", label = T("menu.open", "Open") }
  for _, action in ipairs(launchableActions(result.entry)) do
    items[#items + 1] = { id = "act:" .. action.position, label = action.name }
  end
  if result.provider == "Applications" and result.inFolder == nil then
    items[#items + 1] = { kind = "separator" }
    if result.pinned then
      items[#items + 1] = { id = "unpin", label = T("menu.unpin", "Unpin from Launcher") }
    else
      items[#items + 1] = { id = "pin", label = T("menu.pin", "Pin to Launcher") }
    end
    items[#items + 1] = { kind = "separator" }
    items[#items + 1] = { id = "edit", label = T("menu.edit", "Edit layout…") }
  end
  local opened = panel.openContextMenu({
    items = items,
    onActivate = "onResultMenu",
    context = result.id,
    maxVisible = MENU_MAX_VISIBLE,
  })
  return opened == true
end

-- Menu callbacks resolve the result by id from either tile list.
local function findResultById(id)
  for index, item in ipairs(results) do
    if item.id == id then
      return index, results
    end
  end
  for index, item in ipairs(folderResults) do
    if item.id == id then
      return index, folderResults
    end
  end
  return nil, nil
end

function onResultMenu(actionId, context)
  if not isOpen or type(actionId) ~= "string" or type(context) ~= "string" then
    return
  end
  local index, list = findResultById(context)
  if index == nil then
    return
  end
  local result = list[index]
  if actionId == "open" then
    activate(index)
  elseif actionId == "edit" then
    enterEditMode()
  elseif actionId == "pin" or actionId == "unpin" then
    if result.entry ~= nil then
      setPinned(result.entry.path, actionId == "pin")
    end
  elseif actionId:sub(1, 4) == "act:" then
    local position = tonumber(actionId:sub(5))
    if position == nil or result.entry == nil then
      return
    end
    for _, action in ipairs(launchableActions(result.entry)) do
      if action.position == position then
        recordUsage("Applications", result.entry.path)
        launchExec({ exec = action.exec, terminal = result.entry.terminal })
        finish()
        return
      end
    end
  end
end

function onSubmit(value)
  if folderOpen ~= nil then
    return
  end
  if type(value) == "string" and value ~= query then
    query = value
    refresh()
  end
  activate(selected)
end

local function moveSelection(delta)
  if #results == 0 then
    return
  end
  local nextIndex = selected + delta
  if nextIndex < 1 then
    nextIndex = 1
  elseif nextIndex > #results then
    nextIndex = #results
  end
  if nextIndex ~= selected then
    selected = nextIndex
  end
  if selected > resultsShown then
    resultsShown = math.min(selected + RESULTS_PER_FRAME, #results)
  end
  hoverIndex = nil
  keyboardFocus = true
  render()
end

function onResultHover(state, key)
  if not isOpen then
    return
  end
  if state == "true" then
    -- Tiles and rows report the transparent overlay button's key.
    local index = tonumber(string.match(key or "", "^ov%-(%d+)$"))
    if index == nil then
      return
    end
    if hoverIndex == index and not keyboardFocus then
      return
    end
    hoverIndex = index
    hoverFolder = folderOpen ~= nil
    keyboardFocus = false
    selected = index
    render()
  elseif hoverIndex ~= nil or keyboardFocus then
    -- The host reports a leave only for the tile that owns the hover, so any
    -- leave clears the pointer focus even if its key is not the one we stored.
    hoverIndex = nil
    hoverFolder = false
    keyboardFocus = false
    render()
  end
end

function onKey(chord, pressed)
  if not isOpen or pressed ~= true then
    return
  end
  if folderOpen ~= nil then
    return
  end
  if chord == "Ctrl+e" then
    if mode == "edit" then
      exitEditMode()
    else
      enterEditMode()
    end
    return
  end
  if mode == "edit" then
    return
  end
  local columns = isGrid() and 5 or 1
  if chord == "Down" or chord == "Ctrl+j" or chord == "Ctrl+n" then
    moveSelection(columns)
  elseif chord == "Up" or chord == "Ctrl+k" or chord == "Ctrl+p" then
    moveSelection(-columns)
  elseif isGrid() and (chord == "Right" or chord == "Ctrl+f") then
    moveSelection(1)
  elseif isGrid() and (chord == "Left" or chord == "Ctrl+b") then
    moveSelection(-1)
  elseif chord == "Prior" then
    moveSelection(-columns * 5)
  elseif chord == "Next" then
    moveSelection(columns * 5)
  end
end

function onFrameTick(_deltaMs)
  local needsRender = false
  local refreshTick = false
  if flags.apps then
    flags.apps = false
    -- Score and rebuild are both heavy; give each its own frame so the pair
    -- never crowds the 25 ms budget on a cold machine. The first scan frame
    -- also pays for the freshly decoded catalog's GC step, which can push it
    -- over the budget: retry once on the next frame (never more, or the host's
    -- three consecutive timeouts would disable the panel) so a cold-start blip
    -- cannot leave the grid empty.
    local ok = pcall(refresh)
    if not ok and not flags.retried then
      flags.retried = true
      flags.apps = true
      panel.setNeedsFrameTick(true)
      return
    end
    flags.retried = false
    flags.render = true
    refreshTick = true
  end
  if not refreshTick then
    if flags.render then
      flags.render = false
      needsRender = true
    end
    if flags.more then
      if mode == "edit" then
        editShown = editShown + RESULTS_PER_FRAME
      else
        resultsShown = math.min(resultsShown + RESULTS_PER_FRAME, #results)
      end
      needsRender = true
    end
    local drained = false
    if not needsRender and #iconQueue > 0 then
      -- A frame either builds the tree or resolves icons: chunk and refresh
      -- frames skip the queue, quiet frames spend a small time budget on it.
      -- Resolved icons are drawn on a later frame so a slow lookup never stacks
      -- with a rebuild.
      local started = os.clock()
      local resolved = 0
      while #iconQueue > 0 and resolved < ICONS_PER_TICK do
        -- Peek, resolve, then drop: if the lookup blows the callback budget the
        -- unwound frame never runs the removal, so the head job is retried on
        -- the next tick (the host's icon cache answers the repeat quickly).
        local job = iconQueue[1]
        local path = noctalia.appIconPath(job.name, job.size)
        table.remove(iconQueue, 1)
        if type(path) == "string" and path ~= "" then
          iconCache[job.key] = path
          iconStore.dirty = true
          resolved = resolved + 1
        else
          iconCache[job.key] = false
        end
        if (os.clock() - started) * 1000 >= ICON_LOOKUP_BUDGET_MS then
          break
        end
      end
      if resolved > 0 then
        flags.icons = true
      end
      drained = true
      if #iconQueue == 0 then
        -- Draw every resolved icon in one pass instead of one rebuild per
        -- batch, and persist the cache now that the queue is settled.
        if iconStore.dirty then
          saveIconCache()
          iconStore.dirty = false
        end
      end
    end
    if not drained and flags.icons then
      flags.icons = false
      needsRender = true
    end
  end
  if needsRender or flags.icons then
    -- A render that overruns unwinds mid-tree; without this guard the pending
    -- flags would retry every frame until the host disables the panel.
    local ok = pcall(render)
    if not ok then
      flags.more = false
      flags.icons = false
      flags.render = false
      iconQueue = {}
      iconQueued = {}
      panel.setNeedsFrameTick(false)
      return
    end
  end
  if #iconQueue == 0 and not flags.more and not flags.icons and not flags.render then
    panel.setNeedsFrameTick(false)
  end
end

function onOpen(context)
  isOpen = true
  config = loadConfig()
  loadUsage()
  loadIconCache()
  loadOrder()
  getApplications(false)
  resolvePinned()
  mode = "normal"
  folderOpen = nil
  folderResults = {}
  lastRight.index = nil
  query = type(context) == "string" and context or ""
  providerId = "" -- force a provider reset for the new session
  catFilter = "all"
  selected = 1
  hoverIndex = nil
  keyboardFocus = true
  scrollRev = scrollRev + 1
  calc.result = nil
  calc.expression = nil
  calc.pending = false
  focusInput()
  refresh()
  render()
  refreshWindows(false)
end

function onClose()
  isOpen = false
  hoverIndex = nil
  keyboardFocus = true
  mode = "normal"
  folderOpen = nil
  folderResults = {}
  lastRight.index = nil
  flags.apps = false
  calc.seq = calc.seq + 1
  panel.setNeedsFrameTick(false)
end
