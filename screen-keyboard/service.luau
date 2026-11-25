--!nonstrict
local snapshot = { shown = false, ready = false, caps = false, mods = {}, pending = 0 }
local starting = false
local queue = {}
local running = false
local socketPath = nil
local helperPath = nil
local MODS = { [29] = true, [42] = true, [54] = true, [56] = true,
  [97] = true, [100] = true, [125] = true, [126] = true }

local function publish()
  snapshot.pending = #queue + (running and 1 or 0)
  noctalia.state.set("screen-keyboard.state", snapshot)
end

local function failure(text)
  snapshot.error = text
  snapshot.mods = {}
  queue = {}
  publish()
  noctalia.notifyError(noctalia.tr("title"), text)
end

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function start()
  if snapshot.ready or starting then return end
  local data, err = noctalia.pluginDataDir()
  local dir = noctalia.pluginDir()
  if data == nil or dir == nil then
    failure(err or noctalia.tr("storage_error"))
    return
  end
  socketPath = data .. "/keyboard.sock"
  helperPath = dir .. "/input.py"
  starting = true
  snapshot.error = nil
  publish()
  local accepted = noctalia.runStream("exec python3 -u -B " .. shellQuote(helperPath)
    .. " serve " .. shellQuote(socketPath), function(line)
    local value = noctalia.json.decode(line)
    if type(value) ~= "table" then return end
    if value.event == "ready" then
      starting = false
      snapshot.ready = true
      snapshot.caps = false
      snapshot.error = nil
      publish()
    elseif value.event == "error" then
      starting = false
      snapshot.ready = false
      failure(value.error or noctalia.tr("input_error"))
    elseif value.event == "stopped" then
      starting = false
      snapshot.ready = false
      snapshot.mods = {}
      snapshot.error = snapshot.error or noctalia.tr("input_error")
      queue = {}
      publish()
    end
  end)
  if not accepted then
    starting = false
    failure(noctalia.tr("input_error"))
  end
end

local pump
pump = function()
  if running or #queue == 0 then return end
  if not snapshot.ready then queue = {}; publish(); return end
  local stroke = table.remove(queue, 1)
  local argv = { "python3", "-B", helperPath, "send", socketPath, tostring(stroke.code) }
  for _, code in ipairs(stroke.mods) do table.insert(argv, tostring(code)) end
  running = true
  publish()
  local accepted = noctalia.runAsync(argv, function(result)
    running = false
    local value = noctalia.json.decode(result.stdout or "")
    if result.timedOut or result.exitCode ~= 0 or type(value) ~= "table" or value.ok ~= true then
      failure(type(value) == "table" and value.error or noctalia.tr("input_error"))
      return
    end
    if stroke.code == 58 then snapshot.caps = not snapshot.caps end
    snapshot.error = nil
    publish()
    pump()
  end, 3500)
  if not accepted then
    running = false
    failure(noctalia.tr("input_error"))
  end
end

local function visibility(shown)
  snapshot.shown = shown
  snapshot.mods = {}
  if shown then
    local width = 1060
    local scale = math.max(0.1, tonumber(noctalia.getSetting("accessibility.ui_scale")) or 1)
    local focused = noctalia.focusedOutputName()
    for _, output in ipairs(noctalia.outputs()) do
      if output.name == focused then
        -- outputs().width is already logical; only the plugin UI scale remains.
        width = math.min(width, math.floor((output.width - 24) / scale))
      end
    end
    width = math.max(360, width)
    snapshot.width = width
    noctalia.layer.configure("keyboard", { width = math.floor(width * scale), height = 0,
      keyboard = "none", output = "focused", exclusiveZone = 0 })
    noctalia.layer.show("keyboard")
    start()
  else
    queue = {}
    noctalia.layer.hide("keyboard")
  end
  publish()
end

local function request(value)
  if type(value) ~= "table" then return end
  if value.action == "show" then visibility(true)
  elseif value.action == "hide" then visibility(false)
  elseif value.action == "toggle" then visibility(not snapshot.shown)
  elseif value.action == "retry" then start()
  elseif value.action == "clear" then snapshot.mods = {}; publish()
  elseif value.action == "key" and snapshot.shown then
    local code = tonumber(value.code)
    if code == nil or code ~= math.floor(code) then return end
    if MODS[code] then
      snapshot.mods[tostring(code)] = not snapshot.mods[tostring(code)]
      publish()
      return
    end
    if not snapshot.ready then start(); return end
    if #queue >= 64 then failure(noctalia.tr("queue_full")); return end
    local mods = {}
    for _, modifier in ipairs({ 29, 97, 42, 54, 56, 100, 125, 126 }) do
      if snapshot.mods[tostring(modifier)] then table.insert(mods, modifier) end
    end
    table.insert(queue, { code = code, mods = mods })
    snapshot.mods = {} -- One-shot modifiers, captured before any async work.
    snapshot.error = nil
    publish()
    pump()
  end
end

noctalia.state.watch("screen-keyboard.request", request)
function onIpc(event, _payload)
  request({ action = event })
end
publish()
