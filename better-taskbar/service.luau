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

-- Desktop-entry resolution ---------------------------------------------------
--
-- A window's app_id is a class name (StartupWMClass or an --app-id override),
-- which does not always equal the .desktop id: QQ reports "QQ" while its entry
-- is com.qq.QQ. Pins therefore store resolved desktop ids (what the built-in
-- taskbar does) and launching goes through the entry file itself, so a pin
-- always starts the app it shows.
--
-- The script mirrors the shell's app_identity ranking: exact id, exact
-- StartupWMClass, normalized id, normalized StartupWMClass, name, then the
-- id-tail and unique-token fallbacks. First match per desktop-file id wins, so
-- user-level entries shadow system and Flatpak exports like the XDG spec.
--
--   match|batch <key...>  print "key<TAB>id<TAB>path<TAB>name" per match
--   launch <key>          resolve, then start the entry (gio launch, gtk-launch)
local RESOLVER_SCRIPT = [[
set -u
mode=${1:-match}
shift || true
[ $# -gt 0 ] || exit 1

dirs=()
add_dir() {
  [ -n "$1" ] || return 0
  local d
  for d in "${dirs[@]:-}"; do
    [ "$d" = "$1" ] && return 0
  done
  dirs+=("$1")
}

if [ -n "${XDG_DATA_HOME:-}" ]; then
  add_dir "$XDG_DATA_HOME"
elif [ -n "${HOME:-}" ]; then
  add_dir "$HOME/.local/share"
fi
IFS=':' read -r -a xdg_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${xdg_dirs[@]:-}"; do
  add_dir "$d"
done
add_dir /usr/local/share
add_dir /usr/share
[ -n "${HOME:-}" ] && add_dir "$HOME/.local/share/flatpak/exports/share"
add_dir /var/lib/flatpak/exports/share
add_dir /var/lib/snapd/desktop

files=()
declare -A seen_ids=()
for d in "${dirs[@]}"; do
  appdir="$d/applications"
  [ -d "$appdir" ] || continue
  while IFS= read -r -d '' f; do
    stem=${f##*/}
    stem=${stem%.desktop}
    [ -n "${seen_ids[$stem]:-}" ] && continue
    seen_ids[$stem]=1
    files+=("$f")
  done < <(find "$appdir" -name '*.desktop' \( -type f -o -type l \) -print0 2>/dev/null)
done
[ ${#files[@]} -gt 0 ] || exit 1

keys=$(printf '%s\n' "$@")
result=$(TSV_KEYS="$keys" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-}" awk '
function is_true(v) { v = tolower(v); return v == "true" || v == "1" }

function decode(v,   out, i, c, n) {
  out = ""
  n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      i++
      c = substr(v, i, 1)
      if (c == "s") c = " "
      else if (c == "n") c = "\n"
      else if (c == "t") c = "\t"
      else if (c == "r") c = "\r"
    }
    out = out c
  }
  return out
}

function desktop_visible(only, notl,   m, parts, i, j, found) {
  m = split(tolower(ENVIRON["XDG_CURRENT_DESKTOP"]), parts, ":")
  if (only != "") {
    found = 0
    split(tolower(only), shown, ";")
    for (i = 1; i <= length(shown); i++) {
      if (shown[i] == "") continue
      for (j = 1; j <= m; j++) if (shown[i] == parts[j]) found = 1
    }
    if (!found) return 0
  }
  if (notl != "") {
    split(tolower(notl), hidden, ";")
    for (i = 1; i <= length(hidden); i++) {
      if (hidden[i] == "") continue
      for (j = 1; j <= m; j++) if (hidden[i] == parts[j]) return 0
    }
  }
  return 1
}

function ident(v) { v = tolower(v); gsub(/[._[:space:]-]/, "", v); return v }

function commit(   id, nm) {
  if (curfile == "") return
  id = curfile
  sub(/^.*\//, "", id)
  sub(/\.desktop$/, "", id)
  if (tolower(t_type) != "application") return
  nm = decode(t_name)
  if (nm == "") return
  if (is_true(t_hidden) || is_true(t_nodisplay)) return
  if (!desktop_visible(t_only, t_not)) return
  n++
  eid[n] = id
  epath[n] = curfile
  ename[n] = nm
  eswc[n] = decode(t_swc)
}

function strength(i, v,   iv, iid, iswc) {
  iid = tolower(eid[i])
  iswc = tolower(eswc[i])
  if (v == iid) return 6
  if (iswc != "" && v == iswc) return 5
  iv = ident(v)
  if (iv != "" && iv == ident(iid)) return 4
  if (iv != "" && iswc != "" && iv == ident(iswc)) return 3
  if (v == tolower(ename[i])) return 2
  return 0
}

function find_best(v,   i, s, best, bests, amb) {
  best = 0; bests = 0; amb = 0
  for (i = 1; i <= n; i++) {
    s = strength(i, v)
    if (s > bests) { best = i; bests = s; amb = 0 }
    else if (s > 0 && s == bests && best > 0 && eid[i] != eid[best]) amb = 1
  }
  if (amb) return 0
  return best
}

function tail_of(v,   t) {
  t = v
  sub(/^.*\//, "", t)
  sub(/^.*\./, "", t)
  return tolower(t)
}

function find_tail(key, v,   k, i, count, last, hits) {
  k = tail_of(key)
  if (k == "" || k == v) return 0
  count = 0; last = 0
  for (i = 1; i <= n; i++) if (tail_of(eid[i]) == k) { count++; last = i }
  if (count == 0) return 0
  if (count == 1) return last
  hits = 0
  for (i = 1; i <= n; i++) {
    if (tail_of(eid[i]) == k && strength(i, v) > 0) { hits++; last = i }
  }
  if (hits == 1) return last
  return 0
}

function add_tokens(v, into,   m, parts, i) {
  m = split(tolower(v), parts, /[^a-z0-9]+/)
  for (i = 1; i <= m; i++) {
    if (length(parts[i]) < 4) continue
    if (parts[i] == "app" || parts[i] == "application" || parts[i] == "client") continue
    if (parts[i] == "desktop" || parts[i] == "flatpak" || parts[i] == "gui") continue
    if (parts[i] == "launcher" || parts[i] == "linux" || parts[i] == "wrapped") continue
    into[parts[i] ] = 1
  }
}

function find_tokens(key,   app, etok, t, i, score, best, bests, amb, count) {
  split("", app)
  add_tokens(key, app)
  count = 0
  for (t in app) count++
  if (count == 0) return 0
  best = 0; bests = 0; amb = 0
  for (i = 1; i <= n; i++) {
    split("", etok)
    add_tokens(eid[i], etok)
    add_tokens(eswc[i], etok)
    score = 0
    for (t in app) if (t in etok) score += length(t)
    if (score > bests) { best = i; bests = score; amb = 0 }
    else if (score > 0 && score == bests && best > 0 && eid[i] != eid[best]) amb = 1
  }
  if (amb) return 0
  return best
}

BEGIN { n = 0; curfile = ""; group = "" }

FNR == 1 {
  commit()
  curfile = FILENAME
  group = ""
  t_type = ""; t_name = ""; t_swc = ""
  t_hidden = ""; t_nodisplay = ""; t_only = ""; t_not = ""
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^\[/) { group = line; next }
  if (group != "[Desktop Entry]") next
  p = index(line, "=")
  if (p <= 1) next
  k = substr(line, 1, p - 1)
  v = substr(line, p + 1)
  if (k == "Type") t_type = v
  else if (k == "Name") t_name = v
  else if (k == "StartupWMClass") t_swc = v
  else if (k == "Hidden") t_hidden = v
  else if (k == "NoDisplay") t_nodisplay = v
  else if (k == "OnlyShowIn") t_only = v
  else if (k == "NotShowIn") t_not = v
}

END {
  commit()
  count = split(ENVIRON["TSV_KEYS"], keys, "\n")
  for (ki = 1; ki <= count; ki++) {
    key = keys[ki]
    if (key == "") continue
    v = tolower(key)
    idx = find_best(v)
    if (idx == 0) idx = find_tail(key, v)
    if (idx == 0) idx = find_tokens(key)
    if (idx == 0) continue
    printf "%s\t%s\t%s\t%s\n", key, eid[idx], epath[idx], ename[idx]
  }
}
' "${files[@]}" 2>/dev/null)

[ -n "$result" ] || exit 1

case "$mode" in
  match|batch)
    printf '%s\n' "$result"
    ;;
  launch)
    line=$(printf '%s\n' "$result" | head -n 1)
    id=$(printf '%s\n' "$line" | cut -f 2)
    path=$(printf '%s\n' "$line" | cut -f 3)
    if command -v gio >/dev/null 2>&1 && [ -n "$path" ] && [ -f "$path" ]; then
      gio launch "$path" </dev/null >/dev/null 2>&1
      exit $?
    fi
    if command -v gtk-launch >/dev/null 2>&1 && [ -n "$id" ]; then
      gtk-launch "$id" </dev/null >/dev/null 2>&1
      exit $?
    fi
    exit 4
    ;;
  *)
    exit 2
    ;;
esac
]]

-- lowercased app id or desktop id -> { id = <desktop id>, path = <entry>, name = <Name> }
local appInfo = {}
-- lowercased key -> true when the lookup found nothing (do not retry)
local appMissing = {}
-- lowercased key -> true while a batch is in flight
local resolving = {}
-- forward declarations: resolution publishes, publishing starts resolution
local publish = nil
local resolvePending = nil

local function splitTabs(line)
  local fields = {}
  local start = 1
  while true do
    local tab = string.find(line, "\t", start, true)
    if tab == nil then
      table.insert(fields, string.sub(line, start))
      break
    end
    table.insert(fields, string.sub(line, start, tab - 1))
    start = tab + 1
  end
  return fields
end

local function parseResolverOutput(text)
  local found = {}
  if type(text) ~= "string" or text == "" then
    return found
  end
  for line in string.gmatch(text, "[^\n]+") do
    local fields = splitTabs(line)
    if #fields >= 4 and fields[1] ~= "" and fields[2] ~= "" then
      found[string.lower(fields[1])] = { id = fields[2], path = fields[3], name = fields[4] }
    end
  end
  return found
end

local function runResolver(mode, keys, onDone)
  local argv = { "bash", "-c", RESOLVER_SCRIPT, "better-taskbar-resolver", mode }
  for _, key in ipairs(keys) do
    table.insert(argv, key)
  end
  return noctalia.runAsync(argv, onDone, 15000)
end

-- Remember every answer, including "no entry", so a window app_id is resolved
-- once per session instead of on every snapshot.
local function storeResolution(keys, result)
  local found = parseResolverOutput(result ~= nil and result.stdout or nil)
  for _, key in ipairs(keys) do
    local lowered = string.lower(key)
    local info = found[lowered]
    if info ~= nil then
      appInfo[lowered] = info
      appMissing[lowered] = nil
    else
      appMissing[lowered] = true
    end
  end
  return found
end

local function withDesktopInfo(key, onDone)
  if type(key) ~= "string" or key == "" then
    return
  end
  local lowered = string.lower(key)
  local info = appInfo[lowered]
  if info ~= nil then
    onDone(info)
    return
  end
  if appMissing[lowered] then
    onDone(nil)
    return
  end
  resolving[lowered] = true
  runResolver("batch", { key }, function(result)
    resolving[lowered] = nil
    local found = storeResolution({ key }, result)
    if publish ~= nil then
      publish()
    end
    onDone(found[lowered])
  end)
end

local function stripDesktopId(value)
  local id = string.lower(value)
  if string.sub(id, -8) == ".desktop" then
    return string.sub(id, 1, -9)
  end
  return id
end

local function appDisplayName(appId)
  local info = appInfo[string.lower(appId)]
  if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
    return info.name
  end
  return appId
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

-- Publishes the snapshot and kicks off any missing desktop-entry lookups.
publish = function()
  noctalia.state.set(STATE_KEY, {
    available = available,
    windows = windows,
    workspaces = workspaces,
    pins = pins,
    apps = appInfo,
    error = errorText,
  })
  if resolvePending ~= nil then
    resolvePending()
  end
end

-- Resolve every window app_id and every pin that has no answer yet, in one
-- subprocess. The script is cheap but not free, so answers are cached for the
-- session and only new ids trigger it.
resolvePending = function()
  local wanted = {}
  local seen = {}
  local function consider(value)
    if type(value) ~= "string" or value == "" then
      return
    end
    local lowered = string.lower(value)
    if seen[lowered] then
      return
    end
    seen[lowered] = true
    if appInfo[lowered] == nil and appMissing[lowered] == nil and resolving[lowered] == nil then
      table.insert(wanted, value)
    end
  end
  for _, window in ipairs(windows) do
    consider(window.app_id)
  end
  for _, pin in ipairs(pins) do
    consider(pin)
  end
  if #wanted == 0 then
    return
  end
  for _, key in ipairs(wanted) do
    resolving[string.lower(key)] = true
  end
  runResolver("batch", wanted, function(result)
    for _, key in ipairs(wanted) do
      resolving[string.lower(key)] = nil
    end
    storeResolution(wanted, result)
    publish()
  end)
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

-- Index of the pin matching this app id or its resolved desktop id, 0 if none.
local function pinIndexFor(appId, info)
  local targets = { stripDesktopId(appId) }
  if type(info) == "table" and type(info.id) == "string" then
    table.insert(targets, stripDesktopId(info.id))
  end
  for index, pin in ipairs(pins) do
    local pinned = stripDesktopId(pin)
    for _, target in ipairs(targets) do
      if pinned == target then
        return index
      end
    end
  end
  return 0
end

local function removePinAt(index)
  local nextPins = {}
  for i, pin in ipairs(pins) do
    if i ~= index then
      table.insert(nextPins, pin)
    end
  end
  setPins(nextPins)
end

local function launchApp(appId)
  if type(appId) ~= "string" or appId == "" then
    return
  end
  withDesktopInfo(appId, function(info)
    if info == nil then
      noctalia.notifyError(noctalia.tr("notify.launch_failed", { app = appDisplayName(appId) }))
      return
    end
    runResolver("launch", { appId }, function(result)
      if result == nil or result.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("notify.launch_failed", { app = appDisplayName(appId) }))
      end
    end)
  end)
end

-- Pin/unpin. Pinning stores the resolved desktop id, so a pin always names an
-- entry that exists and can be launched; window class names that resolve to
-- nothing are refused instead of writing a dead entry.
local function togglePin(appId)
  if type(appId) ~= "string" or appId == "" then
    return
  end
  local removed = pinIndexFor(appId, appInfo[string.lower(appId)])
  if removed > 0 then
    removePinAt(removed)
    return
  end
  withDesktopInfo(appId, function(info)
    if info == nil then
      noctalia.notifyError(noctalia.tr("notify.pin_failed", { app = appDisplayName(appId) }))
      return
    end
    local existing = pinIndexFor(appId, info)
    if existing > 0 then
      removePinAt(existing)
      return
    end
    local nextPins = {}
    for _, pin in ipairs(pins) do
      table.insert(nextPins, pin)
    end
    table.insert(nextPins, info.id)
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
  local idx = pinIndexFor(appId, appInfo[string.lower(appId)])
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
  if value.kind == "launch" then
    launchApp(value.app_id)
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
