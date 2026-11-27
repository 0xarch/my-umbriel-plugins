--!nonstrict
local build = require("./view.luau")
local snapshot = noctalia.state.get("screen-keyboard.state") or { mods = {} }
local pendingDrag = nil
local captureReady = false
local pointerMoved = false
local function dragRequest(action, x, y, side)
  noctalia.state.set("screen-keyboard.request", { action = action, x = tonumber(x), y = tonumber(y), side = side })
end

-- Named handlers keep their identity across renders, so updates during capture
-- do not cancel the host's pointer session.
function onDragDown(x, y)
  captureReady = false
  pointerMoved = false
  pendingDrag = nil
  dragRequest("drag-start", x, y)
end
function onRightDragDown(x, y)
  captureReady = false
  pointerMoved = false
  pendingDrag = nil
  dragRequest("drag-start", x, y, "right")
end
function onDragMove(x, y)
  if snapshot.dragging and captureReady then
    pointerMoved = true
    pendingDrag = { x = x, y = y }
  end
end
function onDragUp(x, y)
  pendingDrag = nil
  dragRequest(pointerMoved and "drag-end" or "drag-cancel", x, y)
end
function onDragCancel()
  pendingDrag = nil
  dragRequest("drag-cancel")
end
function onFrameTick(_delta)
  if snapshot.dragging and pendingDrag ~= nil then
    local move = pendingDrag
    pendingDrag = nil
    dragRequest("drag-move", move.x, move.y)
  end
  captureReady = snapshot.dragging == true
  layer.setNeedsFrameTick(snapshot.dragging == true)
end


local function render()
  layer.render(build(snapshot, false))
end
noctalia.state.watch("screen-keyboard.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
    layer.setNeedsFrameTick(snapshot.dragging == true)
  end
end)
render()
