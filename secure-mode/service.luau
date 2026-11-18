--!nonstrict
-- One owner for persistence and filesystem changes, even with several outputs.
local STATE_KEY = "secure-mode.state"
local REQUEST_KEY = "secure-mode.request"
local snapshot = { ready = false, busy = false }

local function publish()
  noctalia.state.set(STATE_KEY, snapshot)
end

local function fail(message)
  snapshot = { ready = false, busy = false, error = message }
  publish()
  noctalia.notifyError(noctalia.tr("title"), message)
end

local function apply(action)
  if snapshot.busy then
    return
  end
  local dir = noctalia.pluginDir()
  local data, err = noctalia.pluginDataDir()
  if dir == nil or data == nil then
    fail(err or noctalia.tr("error.storage"))
    return
  end
  snapshot = { ready = snapshot.ready, enabled = snapshot.enabled, busy = true }
  publish()
  -- argv avoids evaluating paths, labels or state as shell code. Filesystem work
  -- stays outside the host's Luau callback CPU budget.
  local accepted = noctalia.runAsync({ "python3", "-B", dir .. "/secure_mode.py", action, data }, function(result)
    local value = noctalia.json.decode(result.stdout or "")
    if result.timedOut or result.stdoutTruncated or type(value) ~= "table" or type(value.ok) ~= "boolean"
      or (value.ok == true and type(value.enabled) ~= "boolean") then
      -- A killed helper may have partially applied its operation. Never claim
      -- that the previous status is still effective; an explicit retry restores it.
      fail(noctalia.tr("error.operation"))
      return
    end
    snapshot = {
      ready = type(value.enabled) == "boolean",
      enabled = value.enabled,
      busy = false,
      error = value.error,
    }
    publish()
    if value.ok ~= true then
      noctalia.notifyError(noctalia.tr("title"), value.error or noctalia.tr("error.operation"))
    end
  end, 10000)
  if not accepted then
    fail(noctalia.tr("error.operation"))
  end
end

local function request(action)
  if action == "toggle" then
    if snapshot.ready ~= true then
      apply("restore")
      return
    end
    action = snapshot.enabled and "off" or "on"
  end
  if action == "on" or action == "off" or action == "restore" then
    apply(action)
  end
end

noctalia.state.watch(REQUEST_KEY, function(value)
  if type(value) == "table" then
    request(value.action)
  end
end)

function onIpc(event, _payload)
  request(event)
end

publish()
apply("restore")
