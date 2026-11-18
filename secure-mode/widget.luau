--!nonstrict
local snapshot = noctalia.state.get("secure-mode.state") or {}

local function render()
  if snapshot.ready ~= true then
    barWidget.setVisible(snapshot.error ~= nil)
    if snapshot.error ~= nil then
      barWidget.setTooltip(snapshot.error)
      barWidget.render(ui.row({ key = "indicator", align = "center" }, {
        ui.glyph({ name = "alert-triangle", color = "error_container", size = 16 }),
      }))
    end
    return
  end
  local enabled = snapshot.enabled == true
  barWidget.setVisible(enabled or noctalia.getConfig("close-style") == "capsule")
  barWidget.setTooltip(snapshot.error or noctalia.tr(snapshot.busy and "status.busy"
    or (enabled and "status.on" or "status.off")))

  local children = {}
  if enabled and noctalia.getConfig("style") ~= "capsule" then
    children[1] = ui.box({ width = 8, height = 8, radius = 4, fill = "error_container" })
  else
    local text = noctalia.getConfig(enabled and "text" or "close-text")
    if type(text) ~= "string" then
      text = enabled and "SECURE" or "NORMAL"
    end
    children[1] = ui.row({
      key = "capsule", align = "center", justify = "center",
      paddingH = 10, paddingV = 3, radius = 999,
      fill = enabled and "error_container" or "surface_container_high",
    }, {
      ui.label({ text = text, fontSize = 12, fontWeight = "medium", maxWidth = 160, maxLines = 1,
        color = enabled and "on_error_container" or "on_surface_variant" }),
    })
  end
  barWidget.render(ui.row({ key = "indicator", align = "center", justify = "center" }, children))
end

function update()
  render()
end

function onClick()
  if snapshot.busy ~= true then
    noctalia.state.set("secure-mode.request", { action = snapshot.ready and "toggle" or "restore" })
  end
end

noctalia.state.watch("secure-mode.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)
render()
