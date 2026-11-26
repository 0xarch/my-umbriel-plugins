--!nonstrict
local build = require("./view.luau")
local function render(value)
  if type(value) == "table" and value.placement ~= nil then
    layer.render(build(value, true))
  end
end
noctalia.state.watch("screen-keyboard.state", render)
render(noctalia.state.get("screen-keyboard.state"))
