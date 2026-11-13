# Better Launchpad

The built-in Noctalia launcher's Simple layout as a standalone plugin: a search
field, category chips, a five-column app grid or a compact list, and the same
provider prefixes for calculator, emoji, wallpapers, session actions, and open
windows. It follows the user's existing launcher settings instead of keeping a
second set of options.

## Plugin

Plugin id: `io.soloev/better-launchpad`

Entries:

- `launcher` - the bar button. Add it like any other bar widget, or configure it
  with `type = "io.soloev/better-launchpad:launcher"`.
- `launchpad` panel - the floating search panel opened by the button.

Open the panel directly from a terminal:

```sh
noctalia msg panel-toggle io.soloev/better-launchpad:launchpad
```

## Usage

| Input | Effect |
| ----- | ------ |
| Type | Fuzzy-search applications; `/` at the start searches providers |
| Hover | Move the focus to the app under the pointer; leaving the results clears it |
| Up / Down | Move by one row; in a grid, also by one tile with Left / Right |
| Enter | Launch the selected app, copy an emoji or result, apply a wallpaper, run a session action, or focus a window |
| Right-click an app | Open its menu: Open, the desktop actions from the `.desktop` file, Pin/Unpin, and Edit layout |
| Double right-click an app | Enter the layout editor |
| Ctrl+E | Toggle the layout editor |
| Esc | Close the panel |
| Category chip | Filter the current provider (Applications and Emoji) |

Default provider prefixes:

| Prefix | Provider |
| ------ | -------- |
| `/calc` | Calculator (`qalc`) |
| `/emo` | Emoji |
| `/wall` | Wallpapers |
| `/session` | Session actions |
| `/win` | Open windows |
| `/` | Provider overview |

Prefixes, provider globals, and the prefix character come from
`shell.launcher.providers` and `shell.launcher.provider_prefix`. Calculator
results also appear for digit queries in the normal application search.

Applications launch through `gio launch` with the entry's `Exec` as a fallback.
Windows use Umbriel's `window-focus` action, and session actions call
`noctalia msg session <action>`.

## Layout editor

The empty query lists applications in a stored order instead of by usage. The
first scan appends every discovered app to the layout, so a new application
shows up at the end on its first launch. The editor is separate from the normal
mode: no search field, just the stored layout with the same tiles.

- Drag a tile onto another one to reorder; the dragged app takes the target
  slot. The full order is written to `order.json` under the plugin data
  directory after every change.
- The shell's `shell.launcher.pinned` list seeds the front of the layout the
  first time an app is seen. Pin and Unpin from the context menu move the app
  into or out of the pinned block, and the result is stored in `order.json`
  rather than written back to the shell config.
- Each row in `order.json` carries a `type` (`"app"` today) and any extra keys
  are preserved, so folder rows can be added without invalidating a store.

## Settings

The bar button has one plugin setting:

- **Glyph** - the icon shown on the bar button (default: `rocket`).

## Shared settings

The panel reads, but does not modify:

- `shell.launcher.app_grid`, `categories`, `show_icons`, `compact`,
  `sort_by_usage`, `track_usage`, `auto_paste`, and `pinned`
- `shell.launcher.provider_prefix` and `shell.launcher.providers`
- `wallpaper.directory`, `wallpaper.directory_light`, and
  `wallpaper.directory_dark`
- `shell.session.actions`

The built-in launcher's usage and recently-used files are only read. Launches
made from this plugin are recorded in `usage.json` under the plugin data
directory, so uninstalling the plugin does not disturb the shell's history.

## Requirements

- `gio` (recommended) to launch desktop entries. Without it the plugin runs the
  entry's `Exec` line directly.
- `bash` and `awk` to parse desktop entries for application discovery (the helper
  runs off the callback thread so a large catalog stays within the plugin CPU
  budget).
- `qalc` for the calculator provider.
- `umbriel` for the window provider.
- Noctalia 5 with plugin API 46 or newer.

## Notes

- The plugin implements the Simple launcher layout. It does not draw the
  built-in launcher's other layout modes.
- Application discovery reads the XDG application directories, including user
  entries and the Flatpak and Snap export directories. `NoDisplay`,
  `OnlyShowIn`, and `NotShowIn` follow the desktop-entry spec. Entries are parsed
  by `scan-apps.sh` (the same awk approach as `better-taskbar`); the panel decodes
  its JSON asynchronously and renders on the next frame.
- Display names follow the system language from `LC_ALL`, `LC_MESSAGES`, then
  `LANG`: `Name[zh_CN]` (and the `GenericName`, `Comment`, and `Keywords`
  variants) wins over the untranslated value, and every translation stays
  searchable as an alias.
- Tiles are built from fixed-height bands (badges, icon, clipped two-line name,
  origin badge), so the icon and the title's top edge stay put regardless of
  how the name wraps.
- Large catalogs render in chunks of ten results per frame, and icon-theme
  lookups run in a separate frame pass with a small time budget. Resolved icon
  paths are cached in `icon-cache.json` under the plugin data directory, so
  reopening the panel draws every icon immediately; entries whose file no
  longer exists (theme switch, uninstall) are dropped on load.
- Flatpak and Snap entries show a package badge in the tile's bottom-right
  corner, and AppImage entries show the AppImage badge there. The badge's origin
  label appears as the tile tooltip.
- Usage boosting only applies when `shell.launcher.sort_by_usage` is enabled;
  it only affects a typed query, because the empty query follows the stored
  layout.
- A panel control cannot host children, so each tile is a card plus a
  transparent button stretched over it with the compositing `translateY` prop.
  That button is what receives clicks, hover, and right-clicks.
- The native context menu can only be opened from a live pointer callback, so
  there is no keyboard-only equivalent of the right-click menu.

## Development

Headless checks live in `harness/launcher/` at the repository root and need no
Wayland session:

```sh
lua harness/launcher/launcher.lua
python3 -m unittest harness/launcher/test_scan_apps.py   # dev-only check
```

See `harness/launcher/README.md` for the scenarios and the API mock.
