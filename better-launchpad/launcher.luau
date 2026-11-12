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
local emoji = nil
local emojiAt = 0
local wallpapers = nil
local wallpapersAt = 0
local windows = nil
local windowsAt = 0
local windowsLoading = false
local calcResult = nil
local calcFor = nil
local calcSeq = 0
local calcPending = false
local iconCache = {}
local usageBuiltinCounts = {}
local usageBuiltinRecent = {}
local usageOwn = { counts = {}, recent = {} }
local usageOwnPath = nil
local pinnedRank = {}
local pinnedSet = {}
local forceList = false

-- Forward declarations for functions used by asynchronous callbacks.
local refresh
local resolvePinned

-- ── settings ────────────────────────────────────────────────────────────────

local function loadConfig()
  local providers = setting("shell.launcher.providers", {})
  if type(providers) ~= "table" then
    providers = {}
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

-- ── desktop entries ─────────────────────────────────────────────────────────

local function decodeDesktopValue(value)
  local out = {}
  local i = 1
  while i <= #value do
    local ch = value:sub(i, i)
    if ch == "\\" and i < #value then
      local nextCh = value:sub(i + 1, i + 1)
      if nextCh == "s" then
        out[#out + 1] = " "
      elseif nextCh == "n" then
        out[#out + 1] = "\n"
      elseif nextCh == "t" then
        out[#out + 1] = "\t"
      elseif nextCh == "r" then
        out[#out + 1] = "\r"
      elseif nextCh == "\\" then
        out[#out + 1] = "\\"
      else
        out[#out + 1] = nextCh
      end
      i = i + 2
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

local function parseDesktopBool(value)
  local v = lower(trim(value))
  return v == "true" or v == "1" or v == "yes"
end

local function detectOrigin(path)
  local normalized = path:gsub("\\", "/")
  if normalized:find("/flatpak/", 1, true) and normalized:find("/exports/share/applications/", 1, true) then
    return "Flatpak"
  end
  if normalized:find("/snap/", 1, true) or normalized:find("/snapd/desktop/applications/", 1, true) then
    return "Snap"
  end
  if normalized:find("/nix/store/", 1, true) then
    return "Nix"
  end
  local home = noctalia.getenv("HOME") or ""
  local dataHome = noctalia.getenv("XDG_DATA_HOME")
  local userRoot = (type(dataHome) == "string" and dataHome ~= "" and dataHome or (home .. "/.local/share"))
  if startsWith(normalized, userRoot .. "/applications/") then
    return "User"
  end
  return "System"
end

local function originSuffix(origin)
  if origin == "Flatpak" then
    return " · Flatpak"
  elseif origin == "Snap" then
    return " · Snap"
  elseif origin == "Nix" then
    return " · Nix"
  elseif origin == "AppImage" then
    return " · AppImage"
  end
  return ""
end

local currentDesktop = (noctalia.getenv("XDG_CURRENT_DESKTOP") or ""):upper()

local function parseDesktopContent(content, path, id)
  if type(content) ~= "string" or content == "" then
    return nil
  end

  local inMain = false
  local seenMain = false
  local fields = {}
  local localizedNames = {}
  local actionOrder = {}
  local actions = {}

  for rawLine in content:gmatch("([^\n]*)\n?") do
    local line = rawLine:gsub("\r$", "")
    local section = line:match("^%[(.*)%]$")
    if section ~= nil then
      inMain = section == "Desktop Entry"
      if inMain then
        seenMain = true
      end
    elseif inMain and line ~= "" and line:sub(1, 1) ~= "#" then
      local key, value = line:match("^([^=]+)=(.*)$")
      if key ~= nil then
        key = trim(key)
        local baseKey, locale = key:match("^([^%[]+)%[([^%]]+)%]$")
        if baseKey ~= nil then
          if baseKey == "Name" then
            localizedNames[#localizedNames + 1] = decodeDesktopValue(value)
          end
        else
          fields[key] = decodeDesktopValue(value)
        end
      end
    end
  end

  if not seenMain or fields.Type ~= "Application" then
    return nil
  end
  if parseDesktopBool(fields.NoDisplay) or parseDesktopBool(fields.Hidden) then
    return nil
  end
  if fields.Name == nil or trim(fields.Name) == "" then
    return nil
  end

  local onlyShowIn = splitSemicolon(fields.OnlyShowIn)
  if #onlyShowIn > 0 then
    local found = false
    for _, token in ipairs(onlyShowIn) do
      if currentDesktop:find(token:upper(), 1, true) ~= nil then
        found = true
        break
      end
    end
    if not found then
      return nil
    end
  end
  local notShowIn = splitSemicolon(fields.NotShowIn)
  for _, token in ipairs(notShowIn) do
    if currentDesktop:find(token:upper(), 1, true) ~= nil then
      return nil
    end
  end

  local name = trim(fields.Name)
  local entry = {
    id = id,
    path = path,
    name = name,
    nameLower = name:lower(),
    generic = fields.GenericName or "",
    genericLower = lower(fields.GenericName),
    comment = fields.Comment or "",
    exec = fields.Exec or "",
    icon = fields.Icon or "",
    categories = fields.Categories or "",
    keywords = fields.Keywords or "",
    keywordsLower = lower(fields.Keywords),
    startupWmClass = fields.StartupWMClass or "",
    terminal = parseDesktopBool(fields.Terminal),
    origin = detectOrigin(path),
    localizedNames = localizedNames,
  }
  entry.searchNames = { entry.nameLower }
  for _, alias in ipairs(localizedNames) do
    local lowerAlias = lower(alias)
    if lowerAlias ~= entry.nameLower then
      entry.searchNames[#entry.searchNames + 1] = lowerAlias
    end
  end
  if fields.Keywords ~= nil then
    entry.keywordsList = splitSemicolon(fields.Keywords)
  else
    entry.keywordsList = {}
  end
  entry.categoriesList = splitSemicolon(fields.Categories)
  return entry
end

local function appSearchRoots()
  local roots = {}
  local seen = {}

  local function add(path)
    if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path .. "/applications"
    end
  end

  local home = noctalia.getenv("HOME")
  local dataHome = noctalia.getenv("XDG_DATA_HOME")
  add((type(dataHome) == "string" and dataHome ~= "" and dataHome) or (home and (home .. "/.local/share")) or nil)
  local dataDirs = noctalia.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
  for dir in dataDirs:gmatch("([^:]+)") do
    add(dir)
  end
  add("/usr/local/share")
  add("/usr/share")
  if home ~= nil then
    add(home .. "/.local/share/flatpak/exports/share")
  end
  add("/var/lib/flatpak/exports/share")
  add("/var/lib/snapd/desktop")
  return roots
end

-- Discovery runs off the callback thread: `find` produces the candidate list and
-- each desktop file is read with readFileAsync. Parsing a few hundred files in
-- one callback would blow the 25 ms per-callback CPU budget.
local APP_SCAN_INTERVAL = 30
local APP_READ_CONCURRENCY = 8

local function finishAppScan()
  local scan = appScan
  if scan == nil then
    return
  end
  appScan = nil
  local out = scan.out
  table.sort(out, function(a, b)
    if a.nameLower == b.nameLower then
      return a.id < b.id
    end
    return a.nameLower < b.nameLower
  end)
  apps = out
  appsAt = os.time()
  appCategories = nil
  pinnedRank = {}
  pinnedSet = {}
  resolvePinned()
  if isOpen then
    refresh()
    render()
  end
end

local pumpAppScan

local function enqueueDesktopFile(scan, path)
  local name = path:match("([^/]+)$")
  if name == nil or name:sub(-8) ~= ".desktop" then
    return
  end
  local id = name:sub(1, #name - 8)
  if scan.seen[id] then
    return
  end
  scan.seen[id] = true
  scan.queue[#scan.queue + 1] = { path = path, id = id }
end

local function startAppScan()
  if appScan ~= nil then
    return
  end
  local roots = appSearchRoots()
  local scan = {
    queue = {},
    cursor = 1,
    inFlight = 0,
    out = {},
    seen = {},
  }
  appScan = scan

  local argv = { "find" }
  for _, root in ipairs(roots) do
    argv[#argv + 1] = root
  end
  argv[#argv + 1] = "-maxdepth"
  argv[#argv + 1] = "4"
  argv[#argv + 1] = "-name"
  argv[#argv + 1] = "*.desktop"

  local started = noctalia.runAsync(argv, function(result)
    if appScan ~= scan then
      return
    end
    local stdout = type(result) == "table" and result.stdout or ""
    for path in stdout:gmatch("[^\n]+") do
      enqueueDesktopFile(scan, path)
    end
    pumpAppScan()
  end, 15000)

  if not started then
    finishAppScan()
  end
end

pumpAppScan = function()
  local scan = appScan
  if scan == nil then
    return
  end

  while scan.inFlight < APP_READ_CONCURRENCY and scan.cursor <= #scan.queue do
    local item = scan.queue[scan.cursor]
    scan.cursor = scan.cursor + 1
    scan.inFlight = scan.inFlight + 1
    local started = noctalia.readFileAsync(item.path, function(contents)
      if appScan == scan then
        scan.inFlight = scan.inFlight - 1
        if type(contents) == "string" and contents ~= "" then
          local entry = parseDesktopContent(contents, item.path, item.id)
          if entry ~= nil then
            scan.out[#scan.out + 1] = entry
          end
        end
        pumpAppScan()
      end
    end)
    if not started then
      scan.inFlight = scan.inFlight - 1
    end
  end

  if scan.inFlight == 0 and scan.cursor > #scan.queue then
    finishAppScan()
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
  if config == nil or type(config.pinned) ~= "table" then
    return
  end
  local rank = 0
  for _, pin in ipairs(config.pinned) do
    if type(pin) == "string" and pin ~= "" then
      local wanted = pin:gsub("%.desktop$", "")
      local wantedLower = wanted:lower()
      local match = nil
      for _, entry in ipairs(apps or {}) do
        if entry.id == wanted or entry.id:lower() == wantedLower
          or entry.path == pin
          or (entry.startupWmClass ~= "" and (entry.startupWmClass == wanted or entry.startupWmClass:lower() == wantedLower)) then
          match = entry
          break
        end
      end
      if match ~= nil and not pinnedSet[match.path] then
        rank = rank + 1
        pinnedRank[match.path] = rank
        pinnedSet[match.path] = true
      end
    end
  end
end

-- ── emoji ───────────────────────────────────────────────────────────────────

local function getEmoji()
  local now = os.time()
  if emoji ~= nil and now - emojiAt <= 300 then
    return emoji
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
  emoji = out
  emojiAt = now
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
  if windowsLoading then
    return
  end
  if not force and windows ~= nil and now - windowsAt <= 5 then
    return
  end
  windowsLoading = true
  local ok = noctalia.runAsync({ "umbriel", "windows", "--json" }, function(result)
    windowsLoading = false
    windowsAt = os.time()
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
    windows = list
    if isOpen and providerId == "Windows" then
      refresh()
      render()
    end
  end)
  if not ok then
    windowsLoading = false
    windows = {}
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
  local suffix = originSuffix(entry.origin)
  if suffix ~= "" then
    subtitle = (subtitle or "") .. suffix
  end
  return {
    provider = "Applications",
    id = entry.path,
    entry = entry,
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
    table.sort(list, function(a, b)
      local ar = a.rank
      local br = b.rank
      if ar ~= nil and br == nil then
        return true
      end
      if ar == nil and br ~= nil then
        return false
      end
      if ar ~= nil and br ~= nil and ar ~= br then
        return ar < br
      end
      if a.score ~= b.score then
        return a.score > b.score
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
  for _, item in ipairs(windows or {}) do
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
    calcResult = nil
    calcFor = nil
    calcPending = false
    return
  end
  if calcFor == expression then
    return
  end

  calcFor = expression
  calcResult = nil
  calcPending = true
  local seq = calcSeq + 1
  calcSeq = seq

  if not noctalia.commandExists("qalc") then
    calcPending = false
    return
  end

  noctalia.runAsync({ "qalc", "-t", expression }, function(result)
    if seq ~= calcSeq then
      return
    end
    calcPending = false
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
    calcResult = {
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
    list = queryApplications(providerQuery, providerQuery ~= "")
    list = applyCategoryFilter(list)
    list = trimResults(list, 50)

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
    if calcResult ~= nil then
      table.insert(list, 1, calcResult)
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
    if calcResult ~= nil then
      list = { calcResult }
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
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function isGrid()
  if not config.appGrid or not config.showIcons or forceList then
    return false
  end
  return providerId == "Applications" or providerId == "Emoji"
    or providerId == "Wallpaper" or providerId == "Session" or providerId == "Overview"
end

local function resolveIcon(name, size)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local key = name .. "@" .. tostring(size)
  local cached = iconCache[key]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end
  local path = noctalia.appIconPath(name, size)
  if type(path) == "string" and path ~= "" then
    iconCache[key] = path
    return path
  end
  iconCache[key] = false
  return nil
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

local function tile(result, index)
  local fill = nil
  if selected == index then
    fill = "primary/0.16"
  end
  local iconWidth, iconHeight = 40, 40
  if result.imagePath ~= nil then
    iconWidth, iconHeight = 74, 40
  end
  local children = { iconNode(result, iconWidth, iconHeight) }
  children[#children + 1] = ui.label({
    text = result.title,
    fontSize = 11,
    maxLines = 2,
    textAlign = "center",
    color = selected == index and "on_surface" or "on_surface_variant",
    height = 26,
  })
  return ui.column({
    key = "res-" .. index,
    flexGrow = 1,
    height = 86,
    gap = 4,
    padding = 5,
    align = "center",
    justify = "center",
    radius = 10,
    fill = fill,
    onClick = function() activate(index) end,
  }, children)
end

local function listRow(result, index)
  local fill = nil
  if selected == index then
    fill = "primary/0.16"
  end
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
  local right = nil
  if result.pinned then
    right = ui.glyph({ name = "pin-filled", size = 14, color = "primary" })
  elseif result.provider == "Calculator" then
    right = ui.glyph({ name = "copy", size = 14, color = "on_surface_variant" })
  end
  local children = { iconNode(result, 32, 32), text }
  if right ~= nil then
    children[#children + 1] = right
  end
  return ui.row({
    key = "res-" .. index,
    height = 54,
    gap = 12,
    paddingH = 10,
    paddingV = 6,
    align = "center",
    radius = 10,
    fill = fill,
    onClick = function() activate(index) end,
  }, children)
end

local function resultNodes()
  local nodes = {}
  if isGrid() then
    local row = {}
    for index, result in ipairs(results) do
      row[#row + 1] = tile(result, index)
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
    for index, result in ipairs(results) do
      nodes[#nodes + 1] = listRow(result, index)
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
  elseif calcPending then
    body = T("calculator.pending", "Calculating…")
  end
  return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = "search-off", size = 28, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = body, fontSize = 12, color = "on_surface_variant", textAlign = "center", maxWidth = 320 }),
  })
end

function render()
  if not isOpen then
    return
  end

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
      focus = true,
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

  local countText = tostring(#results) .. " " .. T("results", "results")
  if #results == 1 then
    countText = "1 " .. T("result", "result")
  end
  root[#root + 1] = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({
      text = T("hint", "↑↓ navigate · Enter open · Esc close"),
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.label({ text = countText, fontSize = 10, color = "on_surface_variant" }),
  })

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, root))
end

-- ── activation ──────────────────────────────────────────────────────────────

local function focusInput()
  inputRev = inputRev + 1
end

function setQuery(value)
  query = value or ""
  selected = 1
  scrollRev = scrollRev + 1
  focusInput()
  refresh()
  render()
end

function setCategory(id)
  catFilter = id
  selected = 1
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

function activate(index)
  local result = results[index]
  if result == nil then
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

function onSubmit(value)
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
    render()
  end
end

function onKey(chord, pressed)
  if not isOpen or pressed ~= true then
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

function onOpen(context)
  isOpen = true
  config = loadConfig()
  loadUsage()
  getApplications(false)
  resolvePinned()
  query = type(context) == "string" and context or ""
  providerId = "" -- force a provider reset for the new session
  catFilter = "all"
  selected = 1
  scrollRev = scrollRev + 1
  calcResult = nil
  calcFor = nil
  calcPending = false
  focusInput()
  refresh()
  render()
  refreshWindows(false)
end

function onClose()
  isOpen = false
  calcSeq = calcSeq + 1
end
