--!nonstrict
-- Remains reachable when the disabled bar indicator is configured to hide.
local snapshot = noctalia.state.get("secure-mode.state") or {}

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("shield-lock")
  shortcut.setActive(snapshot.ready == true and snapshot.enabled == true)
  shortcut.setEnabled(snapshot.busy ~= true)
end

function onClick()
  if snapshot.busy ~= true then
    noctalia.state.set("secure-mode.request", { action = snapshot.ready and "toggle" or "restore" })
  end
end

function update()
  render()
end

noctalia.state.watch("secure-mode.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)
render()
