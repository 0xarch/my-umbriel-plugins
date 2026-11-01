--!nonstrict
-- Better Taskbar service - one Umbriel event stream, one pin list, one action queue.
--
-- `umbriel subscribe windows,workspaces` writes one JSON snapshot per line. The
-- service keeps the newest of each family and republishes them together, so
-- every bar widget on every output renders from the same state without opening
-- a stream of its own. Pins are persisted under the plugin data directory
-- because the shell does not let a plugin write its own settings.
--
--   noctalia.runStream(cmd, onLine)                  long-lived child
--   noctalia.umbriel.action(request, cb)             one typed compositor action
--   noctalia.state.set("better-taskbar.state", snap) published snapshot
--   noctalia.state.watch("better-taskbar.request")   widget/panel requests

local STATE_KEY = "better-taskbar.state"
local REQUEST_KEY = "better-taskbar.request"
local RECONNECT_INTERVAL_MS = 1000
-- runStream has no exit callback, so report termination on stdout and let the
-- next tick reconnect. The same trick the official Umbriel Companion uses.
local STREAM_COMMAND =
  [[umbriel subscribe windows,workspaces; printf '\n{"event":"better-taskbar-disconnected"}\n']]

local available = false
local streaming = false
local windows = {}
local workspaces = {}
local errorText = nil
local pins = {}

local function socketPath()
  local explicit = noctalia.getenv("UMBRIEL_SOCKET")
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local display = noctalia.getenv("WAYLAND_DISPLAY")
  if runtimeDir ~= nil and runtimeDir ~= "" and display ~= nil and display ~= "" then
    return runtimeDir .. "/umbriel-" .. display .. ".sock"
  end
  return nil
end

local function pinsPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/pins.json"
end

local function copyStringList(value)
  local out = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "string" and item ~= "" then
        table.insert(out, item)
      end
    end
  end
  return out
end

local function savePins()
  local path = pinsPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(pins)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

-- A pin doubles as a gtk-launch desktop ID, so only IDs with a matching
-- .desktop file are pinnable. Window app_ids (class names) do not always
-- correspond to one (StartupWMClass, --app-id overrides), so verify before
-- adding. Checks the standard XDG application directories; dotted IDs may
-- exist either flat (org.kde.dolphin.desktop) or as a path (org/kde/...).
local DESKTOP_CHECK_SNIPPET = [[
id="${1%.desktop}"; p="${id//./\/}"; found=1
IFS=':' read -ra dirs <<< "${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:$HOME/.flatpak/exports/share:/var/lib/flatpak/exports/share"
for d in "${dirs[@]}"; do
  [ -f "$d/applications/$id.desktop" ] && { found=0; break; }
  [ -f "$d/applications/$p.desktop" ] && { found=0; break; }
done
exit $found
]]

local function hasDesktopFile(appId, onResult)
  return noctalia.runAsync(
    { "bash", "-c", DESKTOP_CHECK_SNIPPET, "better-taskbar-desktop-check", appId },
    function(result)
      onResult(result ~= nil and result.exitCode == 0)
    end
  )
end

local function loadPins()
  local path = pinsPath()
  if path ~= nil and noctalia.fileExists(path) then
    local raw = noctalia.readFile(path)
    if raw ~= nil and raw ~= "" then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        pins = copyStringList(decoded)
        return
      end
    end
  end
  -- No saved list yet: follow the plugin setting until the first pin action
  -- writes one. Saving here would freeze the setting at its first value.
  pins = copyStringList(noctalia.getConfig("pinned"))
end

local function publish()
  noctalia.state.set(STATE_KEY, {
    available = available,
    windows = windows,
    workspaces = workspaces,
    pins = pins,
    error = errorText,
  })
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if decoded.event == "better-taskbar-disconnected" then
    streaming = false
    available = false
    windows = {}
    workspaces = {}
    errorText = noctalia.tr("error.stream_closed")
    publish()
    return
  end
  if type(decoded.err) == "string" then
    errorText = decoded.err
    publish()
    return
  end
  if decoded.event == "windows" and type(decoded.data) == "table" then
    windows = decoded.data
  elseif decoded.event == "workspaces" and type(decoded.data) == "table" then
    workspaces = decoded.data
  else
    return
  end
  available = true
  errorText = nil
  publish()
end

local function startStream()
  if streaming then
    return
  end
  local path = socketPath()
  if path == nil or not noctalia.fileExists(path) or not noctalia.commandExists("umbriel") then
    return
  end
  streaming = noctalia.runStream(STREAM_COMMAND, onLine)
  if not streaming then
    errorText = noctalia.tr("error.stream_failed")
    publish()
  end
end

local function runAction(request)
  local accepted = noctalia.umbriel.action(request, function(ok, err)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }), err)
    end
  end)
  if not accepted then
    noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }))
  end
end

local function setPins(nextPins)
  pins = copyStringList(nextPins)
  savePins()
  publish()
end

local function togglePin(appId)
  if type(appId) ~= "string" or appId == "" then
    return
  end
  local lower = string.lower(appId)
  local removed = false
  for _, pin in ipairs(pins) do
    if string.lower(pin) == lower then
      removed = true
      break
    end
  end
  if removed then
    local nextPins = {}
    for _, pin in ipairs(pins) do
      if string.lower(pin) ~= lower then
        table.insert(nextPins, pin)
      end
    end
    setPins(nextPins)
    return
  end
  -- Pinning: require a matching .desktop file, otherwise the entry could
  -- never be launched and its icon lookup would fail.
  hasDesktopFile(appId, function(ok)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.pin_failed"), appId)
      return
    end
    local nextPins = {}
    for _, pin in ipairs(pins) do
      table.insert(nextPins, pin)
    end
    table.insert(nextPins, appId)
    setPins(nextPins)
  end)
end

local function movePin(appId, direction)
  if type(appId) ~= "string" or appId == "" then
    return
  end
  if direction ~= "left" and direction ~= "right" then
    return
  end
  local lower = string.lower(appId)
  local idx = 0
  for i, pin in ipairs(pins) do
    if string.lower(pin) == lower then
      idx = i
      break
    end
  end
  if idx == 0 then
    return
  end
  local targetIdx = direction == "left" and idx - 1 or idx + 1
  if targetIdx < 1 or targetIdx > #pins then
    return
  end
  local nextPins = {}
  for i = 1, #pins do
    if i == idx then
      table.insert(nextPins, pins[targetIdx])
    elseif i == targetIdx then
      table.insert(nextPins, pins[idx])
    else
      table.insert(nextPins, pins[i])
    end
  end
  setPins(nextPins)
end

noctalia.state.watch(REQUEST_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  startStream()
  if value.kind == "pins" and type(value.pins) == "table" then
    setPins(value.pins)
    return
  end
  if value.kind == "toggle-pin" then
    togglePin(value.app_id)
    return
  end
  if value.kind == "pin-move" then
    movePin(value.app_id, value.direction)
    return
  end
  if type(value.request) == "table" and type(value.request.action) == "string" then
    runAction(value.request)
  end
end)

function update()
  startStream()
end

function onConfigChanged()
  -- A fresh install with no pins file follows the setting. Once the user pins
  -- something from the menu, the saved list is authoritative.
  loadPins()
  publish()
end

noctalia.setUpdateInterval(RECONNECT_INTERVAL_MS)
loadPins()
publish()
startStream()
