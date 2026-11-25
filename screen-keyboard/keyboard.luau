--!nonstrict
local snapshot = noctalia.state.get("screen-keyboard.state") or { mods = {} }
local function key(code, label, units)
  return { code = code, label = label, units = units or 1 }
end
local function gap(units) return { units = units } end

-- ANSI US tenkeyless: the 15-unit typing block plus a 3-unit navigation block.
local ROWS = {
  { key(1, "Esc"), gap(1), key(59, "F1"), key(60, "F2"), key(61, "F3"), key(62, "F4"), gap(0.5),
    key(63, "F5"), key(64, "F6"), key(65, "F7"), key(66, "F8"), gap(0.5),
    key(67, "F9"), key(68, "F10"), key(87, "F11"), key(88, "F12") },
  { key(41, "~\n`"), key(2, "!\n1"), key(3, "@\n2"), key(4, "#\n3"), key(5, "$\n4"), key(6, "%\n5"),
    key(7, "^\n6"), key(8, "&\n7"), key(9, "*\n8"), key(10, "(\n9"), key(11, ")\n0"),
    key(12, "_\n-"), key(13, "+\n="), key(14, "Backspace", 2) },
  { key(15, "Tab", 1.5), key(16, "Q"), key(17, "W"), key(18, "E"), key(19, "R"), key(20, "T"),
    key(21, "Y"), key(22, "U"), key(23, "I"), key(24, "O"), key(25, "P"), key(26, "{\n["),
    key(27, "}\n]"), key(43, "|\n\\", 1.5) },
  { key(58, "Caps", 1.75), key(30, "A"), key(31, "S"), key(32, "D"), key(33, "F"), key(34, "G"),
    key(35, "H"), key(36, "J"), key(37, "K"), key(38, "L"), key(39, ":\n;"), key(40, "\"\n'"), key(28, "Enter", 2.25) },
  { key(42, "Shift", 2.25), key(44, "Z"), key(45, "X"), key(46, "C"), key(47, "V"), key(48, "B"),
    key(49, "N"), key(50, "M"), key(51, "<\n,"), key(52, ">\n."), key(53, "?\n/"), key(54, "Shift", 2.75) },
  { key(29, "Ctrl", 1.25), key(125, "Super", 1.25), key(56, "Alt", 1.25), key(57, "Space", 6.25),
    key(100, "AltGr", 1.25), key(126, "Super", 1.25), key(127, "Menu", 1.25), key(97, "Ctrl", 1.25) },
}
local NAV = {
  { key(99, "PrtSc"), key(70, "ScrLk"), key(119, "Pause") },
  { key(110, "Ins"), key(102, "Home"), key(104, "PgUp") },
  { key(111, "Del"), key(107, "End"), key(109, "PgDn") },
  { gap(3) },
  { gap(1), key(103, "↑"), gap(1) },
  { key(105, "←"), key(108, "↓"), key(106, "→") },
}

local function request(action, code)
  noctalia.state.set("screen-keyboard.request", { action = action, code = code })
end

local function render()
  local width = snapshot.width or 1060
  local unit = (width - 24) / 18.5
  local keyHeight = 40
  local fontSize = math.max(8, math.min(12, unit * 0.24))
  local rows = {}
  for index, row in ipairs(ROWS) do
    local nodes = {}
    local function append(items, prefix)
      for col, item in ipairs(items) do
        local cellWidth = item.units * unit
        if item.code == nil then
          table.insert(nodes, ui.row({ key = prefix .. col, width = cellWidth, height = keyHeight }, {}))
        else
          local code = item.code
          local active = (snapshot.mods or {})[tostring(code)] == true or (code == 58 and snapshot.caps == true)
          table.insert(nodes, ui.row({ key = "slot-" .. code, width = cellWidth, height = keyHeight,
            paddingH = 2, paddingV = 2 }, {
            ui.row({ key = "key-" .. code, width = math.max(4, cellWidth - 4), height = keyHeight - 4,
              fill = active and "primary_container" or "surface_container_highest",
              radius = 5, align = "center", justify = "center", onClick = function() request("key", code) end,
              tooltip = item.label:gsub("\n", " / ") }, {
              ui.label({ text = item.label, fontSize = fontSize, fontWeight = "medium",
                color = active and "on_primary_container" or "on_surface", maxLines = 2,
                maxWidth = math.max(4, cellWidth - 6), textAlign = "center" }),
            }),
          }))
        end
      end
    end
    append(row, "main-")
    table.insert(nodes, ui.row({ key = "divider", width = unit * 0.5, height = keyHeight }, {}))
    append(NAV[index], "nav-")
    rows[#rows + 1] = ui.row({ key = "row-" .. index, height = keyHeight }, nodes)
  end
  local status = snapshot.error or noctalia.tr(snapshot.ready and "hint" or "starting")
  local children = {
    ui.row({ key = "header", height = 30, align = "center", gap = 8 }, {
      ui.glyph({ name = "keyboard", size = 18 }),
      ui.label({ text = noctalia.tr("title"), fontWeight = "medium", fontSize = 13 }),
      ui.label({ text = status, fontSize = 11, color = snapshot.error and "error" or "on_surface_variant",
        maxLines = 1, maxWidth = math.max(50, width - 350), flexGrow = 1 }),
      ui.button({ text = noctalia.tr("clear"), onClick = function() request("clear") end }),
      ui.button({ glyph = "refresh", tooltip = noctalia.tr("retry"),
        onClick = function() request("retry") end }),
      ui.button({ glyph = "close", tooltip = noctalia.tr("hide"), onClick = function() request("hide") end }),
    }),
  }
  for _, row in ipairs(rows) do table.insert(children, row) end
  layer.render(ui.column({ key = "keyboard", width = width, padding = 12, gap = 4,
    radius = 12, fill = "surface_container", border = "outline_variant", borderWidth = 1 }, children))
end

noctalia.state.watch("screen-keyboard.state", function(value)
  if type(value) == "table" then snapshot = value; render() end
end)
render()
