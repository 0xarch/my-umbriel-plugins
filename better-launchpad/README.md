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
- Flatpak and Snap entries show a package badge, and AppImage entries show the
  AppImage badge. The badge's origin label appears as the tile tooltip.
- Usage boosting only applies when `shell.launcher.sort_by_usage` is enabled.

## Development

Headless checks live in `harness/launcher/` at the repository root and need no
Wayland session:

```sh
lua harness/launcher/launcher.lua
python3 -m unittest harness/launcher/test_scan_apps.py   # dev-only check
```

See `harness/launcher/README.md` for the scenarios and the API mock.
