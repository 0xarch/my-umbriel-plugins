--!nonstrict
-- Better Taskbar window menu - what a right-click on a tile opens.
--
-- The widget publishes the hovered tile on "better-taskbar.menu" and toggles
-- this panel. Every action is another request on "better-taskbar.request"; the
-- service owns the pin list and the compositor socket.

local STATE_KEY = "better-taskbar.state"
local REQUEST_KEY = "better-taskbar.request"
local MENU_KEY = "better-taskbar.menu"

local target = nil
local snapshot = noctalia.state.get(STATE_KEY)

local function request(actionRequest)
  noctalia.state.set(REQUEST_KEY, { request = actionRequest })
  panel.close()
end

local function primaryWindow()
  if target == nil or type(target.windows) ~= "table" then
    return nil
  end
  for _, window in ipairs(target.windows) do
    if window.active == true then
      return window
    end
  end
  return target.windows[1]
end

local function isPinned()
  if target == nil or type(target.app_id) ~= "string" then
    return false
  end
  local app = string.lower(target.app_id)
  local pins = snapshot ~= nil and type(snapshot.pins) == "table" and snapshot.pins or {}
  for _, pin in ipairs(pins) do
    if string.lower(pin) == app then
      return true
    end
  end
  return false
end

local function pinCount()
  if snapshot == nil or type(snapshot.pins) ~= "table" then
    return 0
  end
  return #snapshot.pins
end

local function render()
  if target == nil then
    panel.render(ui.column({ gap = 8 }, {
      ui.label({ text = noctalia.tr("menu.empty"), color = "on_surface_variant" }),
    }))
    return
  end

  local children = {}
  table.insert(children, ui.label({
    text = target.heading or target.app_id or "",
    fontWeight = "bold",
    fontSize = 14,
    maxLines = 2,
  }))

  local windows = type(target.windows) == "table" and target.windows or {}
  if #windows > 0 then
    table.insert(children, ui.separator({ spacing = 2 }))
    local limit = math.min(#windows, 7)
    for index = 1, limit do
      local window = windows[index]
      table.insert(children, ui.button({
        text = window.title or noctalia.tr("tooltip.window"),
        glyph = window.active == true and "app-window" or "window",
        variant = "ghost",
        contentAlign = "start",
        onClick = function()
          request({ action = "window-focus", window = window.id })
        end,
      }))
    end
    if #windows > limit then
      table.insert(children, ui.label({
        text = noctalia.tr("menu.more", { count = #windows - limit }),
        color = "on_surface_variant",
        fontSize = 11,
      }))
    end
  end

  table.insert(children, ui.separator({ spacing = 2 }))

  local window = primaryWindow()
  if window ~= nil then
    if window.minimizable == true and not window.minimized then
      table.insert(children, ui.button({
        text = noctalia.tr("menu.minimize"),
        glyph = "minus",
        contentAlign = "start",
        variant = "ghost",
        onClick = function()
          request({ action = "window-minimize", window = window.id })
        end,
      }))
    end
    table.insert(children, ui.button({
      text = noctalia.tr("menu.close"),
      glyph = "x",
      contentAlign = "start",
      variant = "ghost",
      onClick = function()
        request({ action = "window-close", window = window.id })
      end,
    }))
  else
    table.insert(children, ui.button({
      text = noctalia.tr("menu.launch"),
      glyph = "rocket",
      contentAlign = "start",
      variant = "ghost",
      enabled = type(target.app_id) == "string" and target.app_id ~= "",
      onClick = function()
        if type(target.app_id) == "string" and target.app_id ~= "" then
          noctalia.runAsync({ "gtk-launch", target.app_id })
        end
        panel.close()
      end,
    }))
  end

  table.insert(children, ui.separator({ spacing = 2 }))

  -- Pin/unpin toggle.
  local pinned = isPinned()
  table.insert(children, ui.button({
    text = pinned and noctalia.tr("menu.unpin") or noctalia.tr("menu.pin"),
    glyph = "pin",
    contentAlign = "start",
    variant = "ghost",
    onClick = function()
      noctalia.state.set(REQUEST_KEY, { kind = "toggle-pin", app_id = target.app_id })
      panel.close()
    end,
  }))

  -- Move left/right for pinned items (reorder without drag-and-drop).
  if pinned and pinCount() > 1 then
    local idx = target.pin_index or 0
    if idx > 1 then
      table.insert(children, ui.button({
        text = noctalia.tr("menu.move_left"),
        glyph = "chevron-left",
        contentAlign = "start",
        variant = "ghost",
        onClick = function()
          noctalia.state.set(REQUEST_KEY, { kind = "pin-move", app_id = target.app_id, direction = "left" })
          panel.close()
        end,
      }))
    end
    if idx < pinCount() then
      table.insert(children, ui.button({
        text = noctalia.tr("menu.move_right"),
        glyph = "chevron-right",
        contentAlign = "start",
        variant = "ghost",
        onClick = function()
          noctalia.state.set(REQUEST_KEY, { kind = "pin-move", app_id = target.app_id, direction = "right" })
          panel.close()
        end,
      }))
    end
  end

  panel.render(ui.column({ gap = 6 }, children))
end

function onOpen()
  target = noctalia.state.get(MENU_KEY)
  snapshot = noctalia.state.get(STATE_KEY)
  render()
end

function onClose()
  target = nil
end

-- The widget publishes the tile and toggles the panel in two calls; the state
-- copy can land after onOpen, so follow the key rather than trusting one read.
noctalia.state.watch(MENU_KEY, function(value)
  if type(value) == "table" then
    target = value
    render()
  end
end)

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)