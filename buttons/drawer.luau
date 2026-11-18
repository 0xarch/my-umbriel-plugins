--!nonstrict
local store = require("./store.luau")
local data, path, raw, loadError
local view = "grid"
local editing = false
local page = 1
local draft, editIndex, layoutDraft
local revision = 0
local pendingDelete = false
local message = ""
local focusMode = false
local swapSource = nil
local states = {}
local opened = false
local render

local function tr(key)
  return noctalia.tr(key)
end

local function button(key, label, callback, extra)
  local props = { key = key, text = tr(label), onClick = callback }
  for k, value in pairs(extra or {}) do props[k] = value end
  return ui.button(props)
end

local function commit(candidate)
  local ok, result = store.save(candidate, path, raw)
  if not ok then
    message = tr(result)
    render()
    return false
  end
  data, raw = candidate, result
  message = ""
  return true
end

local function grid()
  view = "grid"
  draft, layoutDraft = nil, nil
  pendingDelete = false
  swapSource = nil
  message = ""
  render()
end

local function openEditor(index)
  editIndex = index
  local item = index and data.items[index] or nil
  draft = {
    name = item and item.name or "", tooltip = item and item.tooltip or "",
    glyph = item and item.glyph or "terminal", command = item and item.action.command or "",
    state_mode = item and item.state_mode == true or false,
    default_status = item and item.default_status or 0,
  }
  revision = revision + 1
  pendingDelete = false
  swapSource = nil
  message = ""
  view = "editor"
  render()
end

local function saveItem()
  local candidate = store.copy(data)
  local item = {
    id = editIndex and candidate.items[editIndex].id or store.allocateId(candidate),
    name = draft.name, tooltip = draft.tooltip,
    glyph = draft.glyph:find("%S") and draft.glyph or "terminal",
    action = { type = "shell", command = draft.command },
    state_mode = draft.state_mode, default_status = draft.default_status,
  }
  if not store.validateItem(item) then
    message = tr("invalid_item")
    render()
    return
  end
  if editIndex then
    candidate.items[editIndex] = item
  elseif #candidate.items < store.MAX_ITEMS then
    table.insert(candidate.items, item)
  else
    message = tr("item_limit")
    render()
    return
  end
  if commit(candidate) then
    page = math.floor(((editIndex or #candidate.items) - 1) / (data.rows * data.columns)) + 1
    grid()
  end
end

local function deleteItem()
  if not pendingDelete then
    pendingDelete = true
    render()
    return
  end
  local candidate = store.copy(data)
  table.remove(candidate.items, editIndex)
  if commit(candidate) then grid() end
end

local function moveItem(delta)
  local target = editIndex + delta
  if target < 1 or target > #data.items then return end
  local candidate = store.copy(data)
  -- Reordering also saves the current editor values; never silently drop a draft.
  local item = candidate.items[editIndex]
  item.name, item.tooltip = draft.name, draft.tooltip
  item.glyph = draft.glyph:find("%S") and draft.glyph or "terminal"
  item.action.command = draft.command
  item.state_mode, item.default_status = draft.state_mode, draft.default_status
  if not store.validateItem(item) then
    message = tr("invalid_item")
    render()
    return
  end
  candidate.items[editIndex], candidate.items[target] = candidate.items[target], item
  if commit(candidate) then
    editIndex = target
    page = math.floor((target - 1) / (data.rows * data.columns)) + 1
    pendingDelete = false
    render()
  end
end

local function stateFor(item)
  local state = states[item.id]
  if not state or state.command ~= item.action.command or state.baseGlyph ~= item.glyph
    or state.defaultStatus ~= (item.default_status or 0) or state.mode ~= (item.state_mode == true) then
    state = { command = item.action.command, baseGlyph = item.glyph,
      defaultStatus = item.default_status or 0, mode = item.state_mode == true,
      status = item.default_status or 0, glyph = item.glyph, busy = false }
    states[item.id] = state
  end
  return state
end

local function stateError()
  message = tr("status_failed")
  if focusMode and not editing and view == "grid" then
    noctalia.notifyError(tr("title"), message)
  end
end

local function launch(index)
  if editing then openEditor(index) return end
  local item = data.items[index]
  if item.state_mode then
    local state = stateFor(item)
    if state.busy then return end
    state.busy = true
    message = ""
    local accepted = noctalia.runAsync(item.action.command, function(result)
      -- Ignore results from an item that was deleted/reconfigured while running.
      local current
      for _, candidate in ipairs(data and data.items or {}) do
        if candidate.id == item.id then current = candidate break end
      end
      if not current or stateFor(current) ~= state then return end
      state.busy = false
      local status, icon
      if result.exitCode == 0 and not result.timedOut and not result.stdoutTruncated then
        status, icon = store.parseStatus(result.stdout)
      end
      if status ~= nil then
        state.status, state.glyph = status, icon or item.glyph
      elseif opened then
        stateError()
      end
      if opened then render() end
    end, 10000)
    if not accepted then
      state.busy = false
      stateError()
    end
    render()
    return
  end
  -- A string is intentionally passed verbatim to /bin/sh -c; no quoting or
  -- command interpolation by the plugin, no callback/timeout for long-lived apps.
  if noctalia.runAsync(data.items[index].action.command) then
    if data.close_on_run then panel.close() end
  else
    message = tr("launch_failed")
    if focusMode then noctalia.notifyError(tr("title"), message) end
    render()
  end
end

local function swapItem(index)
  if not editing then return end
  if swapSource == nil then
    swapSource = index
    message = ""
    render()
  elseif swapSource == index then
    swapSource = nil
    render()
  else
    local candidate = store.copy(data)
    candidate.items[swapSource], candidate.items[index] = candidate.items[index], candidate.items[swapSource]
    if commit(candidate) then
      swapSource = nil
      render()
    end
  end
end

local function changePage(delta)
  local count = math.max(1, math.ceil(#data.items / (data.rows * data.columns)))
  page = math.max(1, math.min(count, page + delta))
  message = ""
  render()
end

local function openLayout()
  layoutDraft = { rows = data.rows, columns = data.columns, close_on_run = data.close_on_run }
  view = "layout"
  message = ""
  render()
end

local function field(key, label, multiline)
  return ui.column({ key = "field-" .. key, gap = 6 }, {
    ui.label({ text = tr(label), color = "on_surface_variant" }),
    ui.input({
      key = "input-" .. key .. "-" .. tostring(revision), value = draft[key],
      height = multiline and 100 or 38, multiline = multiline or false,
      focus = key == "name", onChange = function(value) draft[key] = value end,
    }),
  })
end

local function editorNodes()
  local nodes = {
    field("name", "name"), field("tooltip", "tooltip"), field("glyph", "glyph"),
    field("command", "command", true),
    ui.label({ text = tr("command_help"), maxLines = 3, color = "on_surface_variant" }),
    ui.row({ gap = 12, align = "center" }, {
      ui.toggle({ key = "state-mode", checked = draft.state_mode, onChange = function(value)
        draft.state_mode = value == "true"
        render()
      end }),
      ui.label({ text = tr("state_mode"), color = "on_surface" }),
    }),
    ui.column({ gap = 6 }, {
      ui.label({ text = tr("default_status"), color = "on_surface_variant" }),
      ui.select({ key = "default-status", options = { tr("status_off"), tr("status_on") },
        selectedIndex = draft.default_status, enabled = draft.state_mode, onChange = function(value)
          draft.default_status = tonumber(value) or 0
          render()
        end }),
    }),
    ui.label({ text = tr("state_help"), maxLines = 5, color = "on_surface_variant" }),
  }
  if editIndex then
    table.insert(nodes, ui.row({ gap = 8 }, {
      button("earlier", "move_earlier", function() moveItem(-1) end, { enabled = editIndex > 1 }),
      button("later", "move_later", function() moveItem(1) end, { enabled = editIndex < #data.items }),
      ui.label({ text = tostring(editIndex) .. " / " .. tostring(#data.items), color = "on_surface_variant" }),
    }))
    table.insert(nodes, button("delete", pendingDelete and "confirm_delete" or "delete", deleteItem,
      { variant = "destructive" }))
  end
  return ui.scroll({ key = "editor", flexGrow = 1, gap = 14 }, nodes)
end

local function layoutNodes()
  local function countControl(key, limit)
    local options = {}
    for i = 1, limit do table.insert(options, tostring(i)) end
    return ui.column({ gap = 8 }, {
      ui.label({ text = tr(key), color = "on_surface_variant" }),
      ui.select({ key = "select-" .. key, options = options, selectedIndex = layoutDraft[key] - 1,
        onChange = function(index)
          layoutDraft[key] = (tonumber(index) or 0) + 1
          render()
        end }),
    })
  end
  return ui.column({ key = "layout", flexGrow = 1, gap = 20 }, {
    countControl("columns", 6), countControl("rows", 5),
    ui.row({ gap = 12, align = "center" }, {
      ui.toggle({ checked = layoutDraft.close_on_run,
        onChange = function(value) layoutDraft.close_on_run = value == "true" render() end }),
      ui.label({ text = tr("close_on_run"), color = "on_surface" }),
    }),
    ui.label({ text = tr("layout_help"), maxLines = 3, color = "on_surface_variant" }),
  })
end

local function gridNodes()
  local capacity = data.rows * data.columns
  local pages = math.max(1, math.ceil(#data.items / capacity))
  page = math.min(page, pages)
  local nodes = {}
  local focused = focusMode and not editing
  local gridHeight = focused and (pages > 1 and 462 or 512) or 356
  if #data.items == 0 then
    local emptyNodes = {
      ui.glyph({ name = "layout-grid", size = 40, color = "primary" }),
      ui.label({ text = tr("empty"), color = "on_surface_variant" }),
    }
    if not focused then
      table.insert(emptyNodes, button("first", "add", function() openEditor(nil) end, { glyph = "plus", variant = "primary" }))
    end
    table.insert(nodes, ui.column({ key = "empty", height = gridHeight, gap = 16, align = "center", justify = "center" }, emptyNodes))
  else
    -- Bounded to at most 30 tiles. No application scan or icon-theme resolution.
    -- Manifest 560 - host padding 28 = 532 logical units, independent of ui_scale.
    local width = math.floor((532 - (data.columns - 1) * 8) / data.columns)
    local height = math.floor((gridHeight - (data.rows - 1) * 8) / data.rows)
    local rows = {}
    for row = 1, data.rows do
      local tiles = {}
      for column = 1, data.columns do
        local index = (page - 1) * capacity + (row - 1) * data.columns + column
        local item = data.items[index]
        if item then
          local state = stateFor(item)
          local active = item.state_mode and state.status == 1
          -- Same transparent full-card button overlay as Better Launchpad:
          -- flex containers cannot receive right-clicks. Keep the original
          -- vertical icon/name layout and colors in a purely visual layer.
          table.insert(tiles, ui.column({ key = "tile-" .. item.id, width = width, height = height }, {
            ui.column({ key = "face-" .. item.id, width = width, height = height,
              gap = 6, padding = 6, align = "center", justify = "center", radius = 10,
              fill = active and "primary" or "surface_container_high",
              border = swapSource == index and (active and "on_primary" or "primary") or "outline_variant",
              borderWidth = swapSource == index and 2 or 0,
              opacity = state.busy and not editing and 0.6 or 1,
            }, {
              ui.glyph({ name = state.glyph, size = data.rows >= 4 and 20 or 30,
                color = active and "on_primary" or "primary" }),
              ui.label({ text = item.name, fontSize = 12, maxLines = data.rows >= 4 and 1 or 2,
                maxWidth = width - 12, textAlign = "center", color = active and "on_primary" or "on_surface" }),
            }),
            ui.button({ key = "item-" .. item.id, width = width, height = height,
              translateY = -height, opacity = 0, variant = "ghost",
              enabled = editing or not state.busy,
              tooltip = item.tooltip ~= "" and item.tooltip or item.name,
              onClick = function() launch(index) end,
              onRightClick = function() swapItem(index) end,
            }),
          }))
        else
          table.insert(tiles, ui.spacer({ key = "blank-" .. column, width = width, height = height }))
        end
      end
      table.insert(rows, ui.row({ key = "row-" .. row, height = height, gap = 8, align = "start" }, tiles))
    end
    table.insert(nodes, ui.column({ key = "tiles", height = gridHeight, gap = 8 }, rows))
  end
  if not focused or pages > 1 then
    table.insert(nodes, ui.row({ key = "pagination", gap = 8, justify = "space_between", align = "center" }, {
      button("previous", "previous", function() changePage(-1) end, { enabled = page > 1 }),
      ui.label({ text = tostring(page) .. " / " .. tostring(pages), color = "on_surface_variant" }),
      button("next", "next", function() changePage(1) end, { enabled = page < pages }),
    }))
  end
  return ui.column({ key = "grid", flexGrow = 1, gap = 12 }, nodes)
end

render = function()
  local header = { ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }) }
  local body
  if loadError then
    body = ui.column({ key = "error", flexGrow = 1, gap = 16 }, {
      ui.label({ text = tr(loadError), maxLines = 4, color = "error" }),
      ui.label({ text = path or "", maxWidth = 532, maxLines = 5, color = "on_surface_variant" }),
    })
  elseif view == "editor" then
    table.insert(header, button("cancel", "cancel", grid))
    table.insert(header, button("save", "save", saveItem, { variant = "primary" }))
    body = editorNodes()
  elseif view == "layout" then
    table.insert(header, button("cancel", "cancel", grid))
    table.insert(header, button("save", "save", function()
      local candidate = store.copy(data)
      candidate.rows, candidate.columns = layoutDraft.rows, layoutDraft.columns
      candidate.close_on_run = layoutDraft.close_on_run
      if commit(candidate) then page = 1 grid() end
    end, { variant = "primary" }))
    body = layoutNodes()
  else
    table.insert(header, button("add", "add", function() openEditor(nil) end,
      { glyph = "plus", enabled = #data.items < store.MAX_ITEMS }))
    table.insert(header, button("edit", editing and "done" or "edit", function()
      editing = not editing
      swapSource = nil
      message = ""
      render()
    end, { selected = editing }))
    table.insert(header, button("layout", "layout", openLayout, { glyph = "settings" }))
    body = gridNodes()
  end
  if noctalia.getSetting("shell.show_close_buttons") ~= false then
    table.insert(header, ui.button({ key = "close", glyph = "x", tooltip = tr("close"), onClick = function() panel.close() end }))
  end
  local nodes = {}
  if loadError or view ~= "grid" or not focusMode or editing then
    table.insert(nodes, ui.row({ key = "header", height = 38, gap = 8, align = "center" }, header))
    table.insert(nodes, ui.label({ key = "status", text = message ~= "" and message or
      (view == "grid" and editing and tr(swapSource and "swap_help" or "edit_help") or ""),
      color = message ~= "" and "error" or "on_surface_variant", fontSize = 12, maxWidth = 532, maxLines = 2 }))
  end
  table.insert(nodes, body)
  panel.render(ui.column({ key = "drawer", flexGrow = 1, gap = 12 }, nodes))
end

function onOpen(_context)
  data, path, raw, loadError = store.load()
  view, editing, page = "grid", false, 1
  draft, layoutDraft = nil, nil
  pendingDelete, message = false, ""
  focusMode = noctalia.getConfig("focus_mode") == true
  swapSource, opened = nil, true
  -- Drop removed items and stale callbacks without losing completed session state.
  local retained = {}
  for _, item in ipairs(data and data.items or {}) do retained[item.id] = stateFor(item) end
  states = retained
  render()
end

function onClose()
  -- Editors use explicit Save; closing or dismissing discards an unsaved draft.
  draft, layoutDraft = nil, nil
  opened, swapSource = false, nil
end

function onKey(chord, pressed)
  if not pressed or loadError or view ~= "grid" then return end
  if chord == "Ctrl+e" then
    editing = not editing
    swapSource, message = nil, ""
    render()
  elseif chord == "Prior" then changePage(-1)
  elseif chord == "Next" then changePage(1) end
end
