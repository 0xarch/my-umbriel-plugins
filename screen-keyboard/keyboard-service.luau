--!nonstrict
local snapshot = { shown = false, ready = false, caps = false, mods = {}, pending = 0 }
local starting = false
local queue = {}
local running = false
local socketPath = nil
local helperPath = nil
local MODS = { [29] = true, [42] = true, [54] = true, [56] = true,
  [97] = true, [100] = true, [125] = true, [126] = true }
local geometry = { width = 1060, key_height = 48, x = 50, y = 100 }
local geometryLoaded = false
local dragging = nil
local placement = nil

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function loadGeometry()
  if geometryLoaded then return end
  local data = noctalia.pluginDataDir()
  if data == nil then return end
  geometryLoaded = true
  local raw = noctalia.readFile(data .. "/geometry.json")
  if raw == nil then return end
  local value = noctalia.json.decode(raw)
  if type(value) ~= "table" then return end
  for key, bounds in pairs({ width = { 640, 2400 }, key_height = { 32, 96 }, x = { 0, 100 }, y = { 0, 100 } }) do
    local number = value[key]
    if type(number) == "number" and number == number then
      geometry[key] = clamp((key == "x" or key == "y") and number or math.floor(number), bounds[1], bounds[2])
    end
  end
end

local function saveGeometry()
  local data, err = noctalia.pluginDataDir()
  if data == nil then return false, err end
  local encoded = noctalia.json.encode(geometry)
  if encoded == nil then return false, noctalia.tr("geometry_error") end
  local temporary = data .. "/geometry.json.tmp"
  local ok, message = noctalia.writeFile(temporary, encoded)
  if not ok then return false, message end
  return noctalia.renameFile(temporary, data .. "/geometry.json")
end

local function configureGeometry()
  local scale = math.max(0.1, tonumber(noctalia.getSetting("accessibility.ui_scale")) or 1)
  local focused = snapshot.output or noctalia.focusedOutputName()
  local screenWidth, screenHeight = 1920, 1080
  local outputs = noctalia.outputs()
  local selected = nil
  for _, output in ipairs(outputs) do
    if output.name == focused then
      selected = output
      break
    end
  end
  if selected == nil then
    for _, output in ipairs(outputs) do
      if output.focused then selected = output; break end
    end
    selected = selected or outputs[1]
  end
  if selected ~= nil then
    screenWidth, screenHeight = selected.width, selected.height
    focused = selected.name
    snapshot.output = focused
  end
  -- Output dimensions are logical pixels. Layer extents use those pixels,
  -- while ui.* geometry is multiplied by accessibility.ui_scale.
  local width = math.min(geometry.width, math.max(1, (screenWidth - 16) / scale))
  local fixedHeight = snapshot.adjusting and 180 or 108
  local keyHeight = math.min(geometry.key_height, math.max(16, ((screenHeight - 16) / scale - fixedHeight) / 6))
  local height = fixedHeight + keyHeight * 6
  local surfaceWidth = math.max(1, math.ceil(width * scale))
  local surfaceHeight = math.max(1, math.ceil(height * scale))
  local left = math.floor(8 + math.max(0, screenWidth - surfaceWidth - 16) * geometry.x / 100)
  local top = math.floor(8 + math.max(0, screenHeight - surfaceHeight - 16) * geometry.y / 100)
  snapshot.width = width
  snapshot.key_height = keyHeight
  snapshot.geometry = { width = geometry.width, key_height = geometry.key_height, x = geometry.x, y = geometry.y }
  placement = { left = left, top = top, width = surfaceWidth, height = surfaceHeight,
    screen_width = screenWidth, screen_height = screenHeight, scale = scale }
  snapshot.placement = placement
  snapshot.dragging = dragging ~= nil
  -- During capture only, use the output as a fixed pointer coordinate space.
  -- The keyboard moves inside it; the captured view never follows the cursor.
  noctalia.layer.configure("keyboard", { anchors = { "top", "left" },
    width = dragging and screenWidth or surfaceWidth, height = dragging and screenHeight or surfaceHeight,
    margins = { top = dragging and 0 or top, left = dragging and 0 or left, right = 0, bottom = 0 },
    keyboard = "none", output = focused or "focused", exclusiveZone = 0 })
end

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
      snapshot.drag_path = value.drag_path
      publish()
    elseif value.event == "error" then
      starting = false
      snapshot.ready = false
      failure(value.error or noctalia.tr("input_error"))
    elseif value.event == "stopped" then
      starting = false
      snapshot.ready = false
      snapshot.drag_path = nil
      if dragging ~= nil then
        dragging = nil
        saveGeometry()
        if snapshot.shown then configureGeometry() end
      end
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
    loadGeometry()
    snapshot.output = noctalia.focusedOutputName()
    configureGeometry()
    noctalia.layer.show("keyboard")
    start()
  else
    if dragging ~= nil then
      dragging = nil
      snapshot.dragging = false
      saveGeometry()
    end
    queue = {}
    noctalia.layer.hide("keyboard")
  end
  publish()
end

local function dragRequest(value)
  if value.action == "drag-start" and snapshot.drag_path ~= nil and placement ~= nil and dragging == nil then
    local x, y = tonumber(value.x), tonumber(value.y)
    if x == nil or y == nil then return end
    dragging = { offset_x = (12 + clamp(x, 0, 1) * (snapshot.width - 24)) * placement.scale,
      offset_y = (12 + clamp(y, 0, 1) * 24) * placement.scale }
    configureGeometry()
    publish()
  elseif (value.action == "drag-move" or value.action == "drag-end" or value.action == "drag-cancel") and dragging ~= nil then
    local x, y = tonumber(value.x), tonumber(value.y)
    if value.action ~= "drag-cancel" and x ~= nil and y ~= nil then
      local rangeX = math.max(0, placement.screen_width - placement.width - 16)
      local rangeY = math.max(0, placement.screen_height - placement.height - 16)
      local left = x * placement.screen_width - dragging.offset_x
      local top = y * placement.screen_height - dragging.offset_y
      if rangeX > 0 then geometry.x = clamp((left - 8) * 100 / rangeX, 0, 100) end
      if rangeY > 0 then geometry.y = clamp((top - 8) * 100 / rangeY, 0, 100) end
    end
    if value.action ~= "drag-move" then
      dragging = nil
      local ok, err = saveGeometry()
      if not ok then noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("geometry_error")) end
    end
    configureGeometry()
    publish()
  end
end

local function adjust(action)
  if action == "adjust" then
    snapshot.adjusting = not snapshot.adjusting
  elseif action == "left" then geometry.x = clamp(geometry.x - 5, 0, 100)
  elseif action == "right" then geometry.x = clamp(geometry.x + 5, 0, 100)
  elseif action == "up" then geometry.y = clamp(geometry.y - 5, 0, 100)
  elseif action == "down" then geometry.y = clamp(geometry.y + 5, 0, 100)
  elseif action == "wider" then geometry.width = clamp(geometry.width + 80, 640, 2400)
  elseif action == "narrower" then geometry.width = clamp(geometry.width - 80, 640, 2400)
  elseif action == "taller" then geometry.key_height = clamp(geometry.key_height + 8, 32, 96)
  elseif action == "shorter" then geometry.key_height = clamp(geometry.key_height - 8, 32, 96)
  elseif action == "center" then geometry.x, geometry.y = 50, 50
  elseif action == "bottom" then geometry.x, geometry.y = 50, 100
  elseif action == "reset" then geometry = { width = 1060, key_height = 48, x = 50, y = 100 }
  else return false end
  if action ~= "adjust" then
    local ok, err = saveGeometry()
    if not ok then noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("geometry_error")) end
  end
  configureGeometry()
  publish()
  return true
end

local function request(value)
  if type(value) ~= "table" then return end
  if value.action == "show" then visibility(true)
  elseif value.action == "hide" then visibility(false)
  elseif value.action == "toggle" then visibility(not snapshot.shown)
  elseif value.action == "retry" then start()
  elseif value.action == "clear" then snapshot.mods = {}; publish()
  elseif snapshot.shown and type(value.action) == "string" and value.action:sub(1, 5) == "drag-" then dragRequest(value)
  elseif snapshot.shown and adjust(value.action) then return
  elseif value.action == "key" and snapshot.shown and dragging == nil then
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
function onOutputsChanged()
  if dragging ~= nil then dragging = nil; saveGeometry() end
  if snapshot.shown then configureGeometry(); publish() end
end
function onConfigChanged()
  if dragging ~= nil then dragging = nil; saveGeometry() end
  if snapshot.shown then configureGeometry(); publish() end
end
publish()
