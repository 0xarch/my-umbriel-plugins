--!nonstrict
local function render()
  barWidget.setGlyph("keyboard")
  barWidget.setTooltip(noctalia.tr("title"))
end
function onClick()
  noctalia.state.set("screen-keyboard.request", { action = "toggle" })
end
function update() render() end
render()
