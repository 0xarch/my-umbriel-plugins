--!nonstrict
-- Only the drawer writes this file. Persist a candidate before committing UI state.
local M = { MAX_ITEMS = 200, MAX_BYTES = 262144 }

local function integer(value, low, high)
  return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

local function text(value, limit, required)
  return type(value) == "string" and #value <= limit and not value:find("%z")
    and (not required or value:find("%S") ~= nil)
end

function M.defaults()
  return { version = 1, rows = 3, columns = 4, close_on_run = true, next_id = 1, items = {} }
end

function M.validateItem(item)
  return type(item) == "table" and text(item.id, 64, true)
    and text(item.name, 160, true) and text(item.tooltip, 512, false)
    and text(item.glyph, 80, true) and type(item.action) == "table"
    and item.action.type == "shell" and text(item.action.command, 16384, true)
    and (item.state_mode == nil or type(item.state_mode) == "boolean")
    and (item.default_status == nil or integer(item.default_status, 0, 1))
end

function M.validate(data)
  if type(data) ~= "table" or data.version ~= 1
    or not integer(data.rows, 1, 5) or not integer(data.columns, 1, 6)
    or type(data.close_on_run) ~= "boolean" or not integer(data.next_id, 1, 1000000000)
    or type(data.items) ~= "table" or #data.items > M.MAX_ITEMS then
    return false
  end
  local seen = {}
  local count = 0
  for index, item in pairs(data.items) do
    if not integer(index, 1, #data.items) or not M.validateItem(item) or seen[item.id] then
      return false
    end
    seen[item.id] = true
    count = count + 1
  end
  return count == #data.items
end

function M.copy(data)
  local copy = {
    version = data.version, rows = data.rows, columns = data.columns,
    close_on_run = data.close_on_run, next_id = data.next_id, items = {},
  }
  for _, item in ipairs(data.items) do
    table.insert(copy.items, {
      id = item.id, name = item.name, tooltip = item.tooltip, glyph = item.glyph,
      action = { type = "shell", command = item.action.command },
      state_mode = item.state_mode == true, default_status = item.default_status or 0,
    })
  end
  return copy
end

function M.parseStatus(output)
  if type(output) ~= "string" or #output > 256 then return nil end
  local status, icon = output:match("^%s*([01])[ \t]+([^%s]+)%s*$")
  if not status then status = output:match("^%s*([01])%s*$") end
  if not status or (icon and not text(icon, 80, true)) then return nil end
  return tonumber(status), icon
end

function M.allocateId(data)
  local used = {}
  for _, item in ipairs(data.items) do used[item.id] = true end
  -- Bounded even if a hand-edited next_id points at an existing item.
  for _ = 1, M.MAX_ITEMS + 1 do
    local id = "button-" .. tostring(data.next_id)
    data.next_id = data.next_id % 1000000000 + 1
    if not used[id] then return id end
  end
  return nil
end

function M.load()
  local dir = noctalia.pluginDataDir()
  if not dir then return nil, nil, nil, "storage_unavailable" end
  local path = dir .. "/items.json"
  local info = noctalia.fileInfo(path)
  if info and (info.isDir or info.size > M.MAX_BYTES) then
    return nil, path, nil, "invalid_storage"
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    -- A missing file is a fresh install; an existing unreadable one is not.
    if noctalia.fileExists(path) then return nil, path, nil, "storage_unavailable" end
    return M.defaults(), path, nil, nil
  end
  if #raw > M.MAX_BYTES then return nil, path, raw, "invalid_storage" end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or not M.validate(data) then return nil, path, raw, "invalid_storage" end
  return data, path, raw, nil
end

function M.save(data, path, previous)
  if not path or not M.validate(data) then return false, "invalid_storage" end
  local current = noctalia.readFile(path)
  if current ~= previous or (current == nil and noctalia.fileExists(path)) then
    return false, "storage_changed"
  end
  local ok, encoded = pcall(noctalia.json.encode, data)
  if not ok or type(encoded) ~= "string" or #encoded > M.MAX_BYTES then
    return false, "storage_too_large"
  end
  -- writeFile truncates; stage and rename in the same directory instead.
  local staged = path .. ".pending"
  if not noctalia.writeFile(staged, encoded) then return false, "save_failed" end
  -- Check again after staging in case another panel instance changed the file.
  current = noctalia.readFile(path)
  if current ~= previous or (current == nil and noctalia.fileExists(path)) then
    return false, "storage_changed"
  end
  if not noctalia.renameFile(staged, path) then return false, "save_failed" end
  return true, encoded
end

return M
