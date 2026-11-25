--!nonstrict
shortcut.setLabel(noctalia.tr("title"))
shortcut.setIcon("keyboard")
shortcut.setEnabled(true)
local function render(value)
  shortcut.setActive(type(value) == "table" and value.shown == true)
end
noctalia.state.watch("screen-keyboard.state", render)
render(noctalia.state.get("screen-keyboard.state"))
function onClick()
  noctalia.state.set("screen-keyboard.request", { action = "toggle" })
end
