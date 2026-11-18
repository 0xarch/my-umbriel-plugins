--!nonstrict
local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "layout-grid")
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel("io.soloev/buttons:drawer")
end

function onIpc(_event, _payload)
  render()
end
