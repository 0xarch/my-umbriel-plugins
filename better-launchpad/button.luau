--!nonstrict
-- Bar button for Better Launchpad. The panel itself lives in launcher.luau.

local PANEL_ID = "io.soloev/better-launchpad:launchpad"
local glyph = noctalia.getConfig("glyph") or "rocket"

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(_event, _payload)
  render()
end
