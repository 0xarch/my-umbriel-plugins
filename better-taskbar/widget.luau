--!nonstrict
-- Better Taskbar bar widget - pinned apps and running windows, the built-in
-- taskbar's job with the plugin API's declarative UI.
--
-- The service owns the Umbriel event stream and the pin list; this script is a
-- pure view. A tile is icon + active dot. Left-click focuses (or launches a
-- pinned app that is not running), middle-click closes, right-click opens the
-- window menu for the tile under the pointer.

local STATE_KEY = "better-taskbar.state"
local REQUEST_KEY = "better-taskbar.request"
local MENU_KEY = "better-taskbar.menu"
local PANEL_ID = "io.soloev/better-taskbar:menu"

local snapshot = noctalia.state.get(STATE_KEY)
local hovered = nil
local hoverTargets = {}
local iconCache = {}
local cycleCursor = {}

local C = {}

local function readConfig()
  local function bool(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) == "boolean" then
      return value
    end
    return fallback
  end
  local function number(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) == "number" then
      return value
    end
    return fallback
  end
  local function text(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) == "string" and value ~= "" then
      return value
    end
    return fallback
  end
  local function list(key)
    local value = noctalia.getConfig(key)
    if type(value) == "table" then
      return value
    end
    return {}
  end

  C = {
    showAllOutputs = bool("show_all_outputs", false),
    onlyActiveWorkspace = bool("only_active_workspace", false),
    showRunning = bool("show_running", true),
    iconScale = number("icon_scale", 1.0),
    itemSpacing = math.floor(number("item_spacing", 4)),
    pinnedOpacity = number("pinned_opacity", 0.5),
    showActiveIndicator = bool("show_active_indicator", true),
    activeIndicatorColor = text("active_indicator_color", "primary"),
    windowIndicatorColor = text("window_indicator_color", "on_surface_variant"),
    middleClick = text("middle_click", "close"),
    activeOpacity = number("active_opacity", 1.0),
    inactiveOpacity = number("inactive_opacity", 1.0),
    showWindowTitle = bool("show_window_title", false),
    windowTitleMaxWidth = math.floor(number("window_title_max_width", 100)),
    taskbarMaxWidth = math.floor(number("taskbar_max_width", 8192)),
    groupByWorkspace = bool("group_by_workspace", false),
    hiddenWorkspaces = list("hidden_workspaces"),
    hideEmptyWorkspaces = bool("hide_empty_workspaces", false),
    groupSingleIconPerApp = bool("group_single_icon_per_app", false),
    workspaceGroupContent = text("workspace_group_content", "icons"),
    workspaceGroupCapsule = bool("workspace_group_capsule", true),
    workspaceGroupActiveBorderColor = text("workspace_group_active_border_color", "primary"),
    workspaceGroupInactiveBorderColor = text("workspace_group_inactive_border_color", "outline_variant"),
    showWorkspaceLabel = bool("show_workspace_label", true),
    minimal = bool("minimal", false),
    focusedColor = text("focused_color", "primary"),
    occupiedColor = text("occupied_color", "secondary"),
    emptyColor = text("empty_color", "secondary"),
    urgentColor = text("urgent_color", "error"),
    configuredPins = list("pinned"),
  }
end

local function iconSize()
  return 16 * C.iconScale
end

local function dotSize()
  return math.max(4, math.floor(16 * 0.32 + 0.5))
end

-- Tile diameter: icon + 4px padding (2px each side), leaving gap from bar edge.
local function tileSize()
  return math.ceil(iconSize() + 4)
end

local function lower(value)
  if type(value) ~= "string" then
    return ""
  end
  return string.lower(value)
end

local function appMatches(windowAppId, pin)
  local app = lower(windowAppId)
  local want = lower(pin)
  if app == "" or want == "" then
    return false
  end
  if app == want then
    return true
  end
  if app .. ".desktop" == want then
    return true
  end
  if want .. ".desktop" == app then
    return true
  end
  return false
end

local function iconPath(appId)
  if type(appId) ~= "string" or appId == "" then
    return nil
  end
  local key = appId .. "@" .. tostring(iconSize())
  local cached = iconCache[key]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end
  local path = noctalia.appIconPath(appId, math.floor(iconSize() * 2))
  if type(path) == "string" and path ~= "" then
    iconCache[key] = path
    return path
  end
  iconCache[key] = false
  return nil
end

local function sendRequest(request)
  noctalia.state.set(REQUEST_KEY, { request = request })
end

local function sendEnvelope(envelope)
  noctalia.state.set(REQUEST_KEY, envelope)
end

local function windowTitle(window)
  if type(window.title) == "string" and window.title ~= "" then
    return window.title
  end
  if type(window.app_id) == "string" and window.app_id ~= "" then
    return window.app_id
  end
  return noctalia.tr("tooltip.window")
end

local function minimizedCount(windows)
  local count = 0
  for _, window in ipairs(windows) do
    if window.minimized == true then
      count = count + 1
    end
  end
  return count
end

local function tileTooltip(tile)
  local windows = tile.windows
  if #windows == 0 then
    if tile.pinned then
      return tile.appId .. "\n" .. noctalia.tr("tooltip.pinned_not_running")
    end
    return tile.appId
  end
  local text = windowTitle(windows[1])
  if #windows > 1 then
    text = text .. "\n" .. noctalia.tr("tooltip.windows", { count = #windows })
  end
  local minimized = minimizedCount(windows)
  if minimized > 0 then
    text = text .. "\n" .. noctalia.tr("tooltip.minimized", { count = minimized })
  end
  return text
end

local function activateWindow(window, allowMinimize)
  if type(window.id) ~= "string" or window.id == "" then
    return
  end
  if allowMinimize and window.active == true and window.minimizable == true then
    sendRequest({ action = "window-minimize", window = window.id })
    return
  end
  sendRequest({ action = "window-focus", window = window.id })
end

local function launchApp(appId)
  if type(appId) ~= "string" or appId == "" then
    return
  end
  if not noctalia.commandExists("gtk-launch") then
    noctalia.notifyError(noctalia.tr("notify.launch_failed"), appId)
    return
  end
  noctalia.runAsync({ "gtk-launch", appId }, function(result)
    if result ~= nil and result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.launch_failed"), appId)
    end
  end)
end

local function activateTile(tile)
  if #tile.windows == 0 then
    if tile.pinned then
      launchApp(tile.appId)
    end
    return
  end
  if #tile.windows == 1 then
    -- Single window: click focuses, clicking again minimizes (native behavior).
    activateWindow(tile.windows[1], true)
    return
  end
  -- Multiple windows: switch straight to the next window, skipping the
  -- minimize attempt (focusing a minimized window restores it).
  local cursor = cycleCursor[tile.key]
  if type(cursor) ~= "number" or cursor < 1 or cursor > #tile.windows then
    cursor = 1
  end
  cycleCursor[tile.key] = (cursor % #tile.windows) + 1
  activateWindow(tile.windows[cursor], false)
end

local function switchWorkspace(workspace)
  local target = workspace.index
  if workspace.named == true and type(workspace.name) == "string" and workspace.name ~= "" then
    target = workspace.name
  end
  sendRequest({
    action = "workspace-switch",
    workspace = target,
    output = workspace.output,
  })
end

local function makeDot(fill, size)
  return ui.box({
    width = size,
    height = size,
    radius = size / 2,
    fill = fill,
  })
end

local function makeTile(tile, showTitles, titleWidth)
  local key = tile.key
  local isVertical = barWidget.isVertical()

  local children = {}
  local path = iconPath(tile.appId)
  if path ~= nil then
    table.insert(children, ui.image({
      path = path,
      width = iconSize(),
      height = iconSize(),
      fit = "contain",
    }))
  else
    table.insert(children, ui.glyph({
      name = "app-window",
      size = iconSize(),
      color = "on_surface",
    }))
  end

  -- Indicator dots: one per window. The focused window's dot uses the active
  -- color, the rest the window indicator color.
  local indicatorChildren = {}
  local winCount = #tile.windows
  if winCount == 1 then
    local fill = C.windowIndicatorColor
    if tile.windows[1].active == true and C.showActiveIndicator then
      fill = C.activeIndicatorColor
    end
    table.insert(indicatorChildren, makeDot(fill, dotSize()))
  elseif winCount > 1 then
    local limit = math.min(winCount, 4)
    for i = 1, limit do
      local fill = C.windowIndicatorColor
      if tile.windows[i].active == true and C.showActiveIndicator then
        fill = C.activeIndicatorColor
      end
      table.insert(indicatorChildren, makeDot(fill, dotSize()))
    end
    if winCount > limit then
      table.insert(indicatorChildren, ui.label({
        text = "+" .. tostring(winCount - limit),
        fontSize = 8,
        color = C.windowIndicatorColor,
      }))
    end
  end

  -- Stack: top spacer + icon + dot row. The negative gap overlays the dots on
  -- the icon's bottom and hangs them ~4px lower; the top spacer (one dot tall)
  -- balances that overhang so the icon stays vertically centered in the tile
  -- and the dot row sits 1px above the tile's bottom edge.
  local stackChildren = { children[1] }
  if #indicatorChildren > 0 then
    table.insert(stackChildren, 1, ui.box({ width = 1, height = dotSize(), fill = "#00000000" }))
    table.insert(stackChildren, ui.row({ gap = 1, align = "center" }, indicatorChildren))
  end

  local iconStack = ui.column({
    gap = 1 - dotSize(),
    align = "center",
    justify = "center",
  }, stackChildren)

  local rowChildren = { iconStack }
  if showTitles then
    table.insert(rowChildren, ui.label({
      text = windowTitle(tile.windows[1]),
      fontSize = 11,
      maxWidth = titleWidth,
      maxLines = 1,
      color = tile.active and "on_surface" or "on_surface_variant",
    }))
  end

  local opacity = tile.active and C.activeOpacity or C.inactiveOpacity
  if tile.pinned and not tile.running then
    opacity = opacity * C.pinnedOpacity
  end

  hoverTargets[key] = {
    key = key,
    app_id = tile.appId,
    pinned = tile.pinned == true,
    running = tile.running == true,
    heading = #tile.windows > 0 and windowTitle(tile.windows[1]) or tile.appId,
    window_count = #tile.windows,
    windows = {},
    pin_index = tile.pinIndex,
  }
  for _, window in ipairs(tile.windows) do
    table.insert(hoverTargets[key].windows, {
      id = window.id,
      title = windowTitle(window),
      minimized = window.minimized == true,
      minimizable = window.minimizable == true,
      active = window.active == true,
    })
  end

  -- Square tile with circular hover; always set fill (even transparent)
  -- so the reconciler clears it on leave.
  local ts = tileSize()
  local isHovered = hovered == key

  return ui.row({
    key = key,
    width = ts,
    height = ts,
    radius = ts / 2,
    align = "center",
    justify = "center",
    opacity = opacity,
    fill = isHovered and "on_surface/0.1" or "#00000000",
    onClick = function()
      activateTile(tile)
    end,
    onHover = "onTileHover",
    tooltip = tileTooltip(tile),
  }, rowChildren)
end

local function isWorkspaceHidden(workspace)
  for _, name in ipairs(C.hiddenWorkspaces) do
    if name == workspace.name or name == workspace.id or tostring(workspace.index) == name then
      return true
    end
  end
  return false
end

local function workspaceLabel(workspace)
  if workspace.named == true and type(workspace.name) == "string" and workspace.name ~= "" then
    return workspace.name
  end
  return tostring(workspace.index)
end

local function workspaceStyle(workspace, occupied)
  if workspace.urgent == true then
    return C.urgentColor, "on_error"
  end
  if workspace.focused == true then
    return C.focusedColor, "on_primary"
  end
  if workspace.occupied == true or occupied then
    return C.occupiedColor, "on_secondary"
  end
  return C.emptyColor, "on_secondary"
end

local function workspaceActive(ws, workspacesById)
  local value = workspacesById[ws.workspace]
  if value == nil then
    return true
  end
  return value.active == true
end

local function buildRenderModel()
  local windows = snapshot.windows or {}
  local workspaces = snapshot.workspaces or {}
  local output = barWidget.outputName()

  local workspacesById = {}
  for _, workspace in ipairs(workspaces) do
    workspacesById[workspace.id] = workspace
  end

  local function outputMatches(name)
    if C.showAllOutputs then
      return true
    end
    if type(output) ~= "string" or output == "" then
      return true
    end
    return name == output
  end

  local filtered = {}
  for _, window in ipairs(windows) do
    if outputMatches(window.output) then
      local workspace = workspacesById[window.workspace]
      local keep = true
      if C.onlyActiveWorkspace and workspace ~= nil and workspace.active ~= true then
        keep = false
      end
      if workspace ~= nil and isWorkspaceHidden(workspace) and workspace.active ~= true then
        keep = false
      end
      if keep then
        table.insert(filtered, window)
      end
    end
  end

  local pins = nil
  if type(snapshot.pins) == "table" and #snapshot.pins > 0 then
    pins = snapshot.pins
  else
    pins = C.configuredPins
  end

  local model = {
    windows = filtered,
    workspaces = {},
    workspacesById = workspacesById,
    output = output,
    pins = pins,
  }

  for _, workspace in ipairs(workspaces) do
    if outputMatches(workspace.output) then
      if not C.onlyActiveWorkspace or workspace.active == true then
        if not isWorkspaceHidden(workspace) or workspace.active == true then
          table.insert(model.workspaces, workspace)
        end
      end
    end
  end

  return model
end

local function buildFlatTiles(model)
  local tiles = {}
  local used = {}
  local pins = model.pins or {}

  for pinIdx, pin in ipairs(pins) do
    local matching = {}
    for index, window in ipairs(model.windows) do
      if not used[index] and appMatches(window.app_id, pin) then
        table.insert(matching, window)
        used[index] = true
      end
    end
    local active = false
    for _, window in ipairs(matching) do
      if window.active == true then
        active = true
        break
      end
    end
    table.insert(tiles, {
      key = "pin:" .. pin,
      appId = pin,
      windows = matching,
      pinned = true,
      running = #matching > 0,
      active = active,
      pinIndex = pinIdx,
    })
  end

  if C.showRunning then
    -- Group non-pinned windows by app_id for merged tiles, then sort
    -- by stable key so focus changes never reorder tiles.
    local byApp = {}
    local appOrder = {}
    for index, window in ipairs(model.windows) do
      if not used[index] then
        local appKey = lower(window.app_id)
        if appKey == "" then
          appKey = window.id
        end
        if byApp[appKey] == nil then
          byApp[appKey] = {
            key = "app:" .. appKey,
            appId = window.app_id,
            windows = {},
            pinned = false,
            running = true,
            active = false,
            pinIndex = 0,
          }
          table.insert(appOrder, appKey)
        end
        table.insert(byApp[appKey].windows, window)
        if window.active == true then
          byApp[appKey].active = true
        end
      end
    end
    table.sort(appOrder)
    for _, appKey in ipairs(appOrder) do
      table.insert(tiles, byApp[appKey])
    end
  end

  return tiles
end

local function buildGroupedTiles(model)
  local groups = {}
  for _, workspace in ipairs(model.workspaces) do
    local wsWindows = {}
    for _, window in ipairs(model.windows) do
      if window.workspace == workspace.id then
        table.insert(wsWindows, window)
      end
    end
    if #wsWindows > 0 or not C.hideEmptyWorkspaces then
      table.insert(groups, {
        workspace = workspace,
        windows = wsWindows,
      })
    end
  end
  return groups
end

local function groupWindowsByApp(windows, prefix)
  local order = {}
  local groups = {}
  for _, window in ipairs(windows) do
    local key = lower(window.app_id)
    if key == "" then
      key = window.id
    end
    if groups[key] == nil then
      groups[key] = {
        key = prefix .. ":" .. key,
        appId = window.app_id,
        windows = {},
        pinned = false,
        running = true,
        active = false,
        pinIndex = 0,
      }
      table.insert(order, key)
    end
    table.insert(groups[key].windows, window)
    if window.active == true then
      groups[key].active = true
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    table.insert(out, groups[key])
  end
  return out
end

local function makeWorkspaceLabel(workspace, occupied)
  local fill, textColor = workspaceStyle(workspace, occupied)
  local label = workspaceLabel(workspace)
  local props = {
    key = "ws:" .. tostring(workspace.id),
    paddingH = 5,
    paddingV = 1,
    radius = 6,
    align = "center",
    onClick = function()
      switchWorkspace(workspace)
    end,
    tooltip = workspaceLabel(workspace),
  }
  local labelColor = textColor
  if C.minimal then
    labelColor = fill
  else
    props.fill = fill
  end
  return ui.row(props, {
    ui.label({
      text = label,
      fontSize = 10,
      fontWeight = "bold",
      color = labelColor,
    }),
  })
end

local function makeWorkspaceContent(group)
  local workspace = group.workspace
  local windows = group.windows
  local nodes = {}

  if C.workspaceGroupContent == "count" then
    table.insert(nodes, ui.row({
      key = "wscount:" .. tostring(workspace.id),
      paddingH = 7,
      paddingV = 2,
      radius = 6,
      fill = "surface_container/0.35",
      onClick = function()
        switchWorkspace(workspace)
      end,
      tooltip = noctalia.tr("tooltip.workspace_windows", { count = #windows }),
    }, {
      ui.label({
        text = tostring(#windows),
        fontSize = 10,
        fontWeight = "bold",
      }),
    }))
    return nodes
  end

  if C.workspaceGroupContent == "dots" then
    local dots = {}
    local limit = math.min(#windows, 5)
    for index = 1, limit do
      local window = windows[index]
      local fill = "on_surface_variant"
      if window.minimized == true then
        fill = "outline_variant"
      end
      if window.active == true and C.showActiveIndicator then
        fill = C.activeIndicatorColor
      end
      table.insert(dots, makeDot(fill, dotSize()))
    end
    if #windows > limit then
      table.insert(dots, ui.label({
        text = "+" .. tostring(#windows - limit),
        fontSize = 9,
        color = "on_surface_variant",
      }))
    end
    table.insert(nodes, ui.row({
      key = "wsdots:" .. tostring(workspace.id),
      gap = 2,
      paddingH = 4,
      paddingV = 3,
      radius = 6,
      align = "center",
      onClick = function()
        switchWorkspace(workspace)
      end,
      tooltip = noctalia.tr("tooltip.workspace_windows", { count = #windows }),
    }, dots))
    return nodes
  end

  if C.groupSingleIconPerApp then
    for _, tile in ipairs(groupWindowsByApp(windows, "grp:" .. tostring(workspace.id))) do
      table.insert(nodes, makeTile(tile, false, 0))
    end
  else
    for _, window in ipairs(windows) do
      table.insert(nodes, makeTile({
        key = "win:" .. window.id,
        appId = window.app_id,
        windows = { window },
        pinned = false,
        running = true,
        active = window.active == true,
        pinIndex = 0,
      }, false, 0))
    end
  end
  return nodes
end

local function makeCapsule(group)
  local workspace = group.workspace
  local children = {}
  if C.showWorkspaceLabel then
    table.insert(children, makeWorkspaceLabel(workspace, #group.windows > 0))
  end

  local content = makeWorkspaceContent(group)
  for _, node in ipairs(content) do
    table.insert(children, node)
  end

  local isActive = workspace.active == true
  return ui.row({
    key = "capsule:" .. tostring(workspace.id),
    gap = 3,
    padding = 2,
    radius = 8,
    align = "center",
    fill = C.workspaceGroupCapsule and "surface_container/0.4" or nil,
    border = C.workspaceGroupCapsule
        and (isActive and C.workspaceGroupActiveBorderColor or C.workspaceGroupInactiveBorderColor)
      or nil,
    borderWidth = C.workspaceGroupCapsule and 1 or 0,
    minHeight = iconSize(),
  }, children)
end

local function render()
  hoverTargets = {}

  if type(snapshot) ~= "table" then
    barWidget.setVisible(false)
    return
  end
  if snapshot.available ~= true then
    local message = type(snapshot.error) == "string" and snapshot.error or ""
    if message == "" then
      barWidget.setVisible(false)
      return
    end
    barWidget.setVisible(true)
    barWidget.render(ui.row({ gap = 4, padding = 2, align = "center", tooltip = message }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
    }))
    return
  end
  barWidget.setVisible(true)

  local model = buildRenderModel()
  local isVertical = barWidget.isVertical()
  local grouped = C.groupByWorkspace and #model.workspaces > 0

  if grouped then
    local capsules = {}
    for _, group in ipairs(buildGroupedTiles(model)) do
      table.insert(capsules, makeCapsule(group))
    end
    local container = isVertical and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center" }, capsules))
    return
  end

  local tiles = buildFlatTiles(model)
  local showTitles = C.showWindowTitle and not isVertical and #tiles > 0
  local titleWidth = 0
  if showTitles then
    local spacing = C.itemSpacing
    local budget = math.floor((C.taskbarMaxWidth - spacing * (#tiles - 1)) / #tiles)
    titleWidth = math.min(C.windowTitleMaxWidth, math.max(0, budget - iconSize() - 10))
    if titleWidth < 16 then
      showTitles = false
    end
  end

  local children = {}
  for _, tile in ipairs(tiles) do
    table.insert(children, makeTile(tile, showTitles, titleWidth))
  end

  local container = isVertical and ui.column or ui.row
  barWidget.render(container({
    gap = C.itemSpacing,
    align = "center",
  }, children))
end

function onTileHover(state, key)
  if state == "true" then
    hovered = key
  elseif state == "false" then
    if hovered == key then
      hovered = nil
    end
  end
  render()
end

-- Pin reorder via menu: move a pinned app one step left or right.
function onPinMove(direction)
  local target = hovered ~= nil and hoverTargets[hovered] or nil
  if target == nil or not target.pinned then
    return
  end
  sendEnvelope({ kind = "pin-move", app_id = target.app_id, direction = direction })
end

function onRightClick()
  local target = hovered ~= nil and hoverTargets[hovered] or nil
  if target == nil then
    return
  end
  noctalia.state.set(MENU_KEY, target)
  noctalia.togglePanel(PANEL_ID)
end

function onMiddleClick()
  local target = hovered ~= nil and hoverTargets[hovered] or nil
  if target == nil then
    return
  end
  -- Configurable middle-click action: launch a new instance or close (default,
  -- matching the built-in taskbar).
  if C.middleClick == "launch" then
    if type(target.app_id) == "string" and target.app_id ~= "" then
      launchApp(target.app_id)
    end
    return
  end
  local window = nil
  for _, candidate in ipairs(target.windows) do
    if candidate.active == true then
      window = candidate
      break
    end
  end
  if window == nil then
    window = target.windows[1]
  end
  if window ~= nil then
    sendRequest({ action = "window-close", window = window.id })
  end
end

function update()
  render()
end

function onConfigChanged()
  readConfig()
  render()
end

readConfig()

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get(STATE_KEY) or snapshot
render()