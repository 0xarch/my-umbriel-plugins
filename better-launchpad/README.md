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

## Folders

The stored layout can hold folders alongside applications. A folder row keeps
its members as desktop paths in their own display order, and membership is
exclusive: a folded application has no top-level row, so it appears only
inside its folder (a typed search still finds it).

- In the app grid a folder renders as a rounded tile with up to four member
  icons (missing members get empty placeholders). The member count is drawn in
  the layout editor only; the normal grid keeps the origin band empty. A new
  folder is named after `folder.new` in the translations, numbered when that
  name is taken.
- Clicking it opens a subview over a scrim that covers the whole panel card,
  including the search bar and the host's content inset. The subview shows the
  members with the same tiles as the main view; clicking the scrim (outside the
  subview) or the header's close button returns to the grid.
- Folders are stored in `order.json` as `{ type = "folder", id = "folder-N",
  name = ..., entries = { ... } }` next to the application rows. A hand-written
  folder without an id gets one assigned on load, and new applications are
  always appended to the top level, never into a folder.

## Layout editor

The empty query lists applications in a stored order instead of by usage. The
first scan appends every discovered app to the layout, so a new application
shows up at the end on its first launch. The editor is separate from the normal
mode: no search field, just the stored layout with the same tiles.

- Drag a tile onto another one to reorder; the dragged app takes the target
  slot. Folders take part in the same drag order, and dropping an application
  on a folder adds it. The full order is written to `order.json` under the
  plugin data directory after every change.
- The header carries a drag-mode switch. **Swap** reorders; **Folder** creates
  folders: drop an app on another app and both go into a new folder placed at
  the target's slot, or drop it on an existing folder to add it there. Folders
  never nest, so dragging a folder changes nothing in folder mode.
  (The drag source only arms on the left button and the API exposes no modifier
  state, so "hold Shift to fold" cannot be a gesture — the switch is the
  equivalent without a keyboard.)
- Click a folder tile to expand it in place: its members follow the tile as
  normal app tiles, and a **Collapse** tile closes the block again. The expanded
  members drag like top-level tiles — dropping one on another member reorders
  the folder, dropping one on a top-level slot moves it out, and dropping a
  top-level app on a member slot inserts it into that folder. Folder mode keeps
  working while expanded: a member dropped on an outer app joins it in a new
  folder.
- While a folder is expanded its icon becomes a pencil. Clicking the tile opens
  a rename box under the editor header; Enter or **Rename** stores the new name
  in `order.json`, and **Cancel** leaves it unchanged.
- The shell's `shell.launcher.pinned` list seeds the front of the layout the
  first time an app is seen. Pin and Unpin from the context menu move the app
  into or out of the pinned block, and the result is stored in `order.json`
  rather than written back to the shell config.
- Each row in `order.json` carries a `type` (`"app"` or `"folder"`) and any
  extra keys are preserved, so future row kinds can be added without
  invalidating a store.

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
- Grid tiles are square: the tile width is derived from the results width
  after reserving the host scroll view's scrollbar gutter (6 + 8 px), so the
  columns never move when a page starts to overflow, and every cell is as tall
  as it is wide. The icon sits in a fixed slot above a clipped two-line name.
  Pinned and origin badges paint over the card through a full-height sibling
  translated up by one tile (the same compositing trick the click target uses),
  so they do not take layout space from the icon and name. The folder subview is
  narrower than the panel, so it derives its own square tile size, and its icon
  and name bands shrink to fit instead of overflowing the smaller tile.
- Large catalogs render in chunks of ten results per frame, and icon-theme
  lookups run in a separate frame pass with a small time budget. Opening the
  panel only queues lookups; filesystem-backed theme resolution never runs in
  the `onOpen` callback. A fixed-size icon slot stays in the layout while the
  queue resolves, and an icon cached at another size is used immediately while
  the exact-size path is refined in a later frame. A genuinely cold icon leaves
  the slot empty until it resolves, rather than flashing a temporary glyph or
  box that changes shape. The layout editor uses the same chunking (and never
  queues icon lookups), so opening it with a large catalog cannot overrun the
  25 ms callback budget and make the host disable the panel. Resolved icon paths
  are cached in `icon-cache.json` under the plugin data directory, so reopening
  the panel draws every icon immediately; entries whose file no longer exists
  (theme switch, uninstall) are dropped on load.
- Flatpak and Snap entries show a package badge in the tile's bottom-right
  corner, and AppImage entries show the AppImage badge there. The badge's origin
  label appears as the tile tooltip.
- Usage boosting only applies when `shell.launcher.sort_by_usage` is enabled;
  it only affects a typed query, because the empty query follows the stored
  layout.
- A panel control cannot host children, so each tile is a card plus a
  transparent button stretched over it with the compositing `translateY` prop.
  That button is what receives clicks, hover, and right-clicks, and it clears
  both the card and the badge overlay stacked between them in layout order.
- The plugin API has no transition or animation props, so the panel animates
  itself from `onFrameTick`: it fades and rises in over 180 ms on open (the host's
  own reveal runs before the script's first tree exists, so it is not visible
  here), and the folder subview's scrim fades in and out over 250 ms. The card
  itself is never scaled or translated, and the easing is applied to the distance
  travelled so the closing scrim fades instead of lingering and snapping away.
  The overlay is staged rather than cross-faded: opening moves the veil's own
  alpha over the first 40% of the fade, then fades the card in over the now
  constant veil; closing runs the sequence backwards. A single cross-fade blends
  the card against a backdrop whose brightness is still moving, so its colour
  visibly drifts mid-fade and reads as a flash instead of a fade. Group opacity
  on the mask is never used (the card would fade with it), and the grid keeps its
  hover highlight, keyboard selection and scroll offset unchanged, because any
  repaint under the veil shows through it. The search field drops the keyboard
  only once the opening veil is opaque and re-takes it only after the close fade
  has finished, because a new input key (the API's only way to move focus)
  rebuilds the control and would flash the field under a still-transparent veil.
  Progress
  is measured against `noctalia.nowMs`, not the frame delta, because the first
  delta after an idle surface can span the whole gap and would skip the fade in
  one step; each step is also capped at ~2 frames so a single slow frame (the
  first layout after a click measured ~97 ms) costs one step, not the fade. Each
  step is a normal render, and the frame loop stays alive until the progress
  reaches its target.
- Noctalia lays the plugin tree out inside its own `Style::panelPadding` (14 px)
  inset on every side, so the tree only owns 532x472 of the 560x500 card. The
  scrim is sized to the card and shifted back out by one content height plus the
  inset; sizing it to the tree instead leaves the card's padding visible on the
  left, top and right while spilling past the card at the bottom. It stops at
  the card's inner edge (one `shell.panel.border_width` plus one logical pixel of
  antialiasing clearance inside, when panel borders are on) so the host's border
  ring stays visible all the way round instead of being painted over, and its
  radius is `Style::radiusXl` times `shell.corner_radius_scale` minus that
  inset, which matches the host's rounded corner. The ring itself is drawn by
  Noctalia (it is the panel card's border, not a plugin node), so the plugin can
  only avoid covering it; at fractional output scales the host's 1 px ring can
  still look uneven between edges, independently of this plugin.
- The grid always renders inside a keyed `content` wrapper under the keyed
  `panel-root`; a folder only adds the scrim as a sibling. Building the root
  differently while a folder is open made the host's reconciler see a (type,
  key) mismatch at the root and rebuild the whole grid, icons included, on every
  open and close. That re-upload is visible under the scrim as a flash, so only
  `folder-mask` opacity changes during the fade.
- The folder subview reuses those tiles, so its overlay keys repeat the grid's.
  Pointer focus is scoped to the list that owns the hover: a hover inside the
  subview never highlights the card at the same index under the scrim.
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
