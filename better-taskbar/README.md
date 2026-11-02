# Better Taskbar

The built-in taskbar as a standalone plugin: a strip of pinned and running window
icons on the bar, optional workspace capsules, and a right-click menu with focus,
minimize, close, and pin actions. It reads Umbriel's IPC window and workspace
streams, so it needs an Umbriel session.

## Plugin

Plugin id: `io.soloev/better-taskbar`

Entries:

- `taskbar` - the bar widget. Add it like any other bar widget, or configure it
  with `type = "io.soloev/better-taskbar:taskbar"`.
- `menu` - the right-click window menu panel.
- `service` - the headless service that owns the Umbriel event stream, the pin
  list, and every compositor action.

Open the menu by right-clicking a taskbar tile:

```sh
noctalia msg panel-toggle io.soloev/better-taskbar:menu
```

## Requirements

- `umbriel` - the compositor must expose its IPC socket (`UMBRIEL_SOCKET`, or
  `$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock`).
- `bash` and POSIX `awk` for the desktop-entry lookup, plus `gio` (or
  `gtk-launch`) to start a pinned app that is not running.

Window `app_id`s are class names, which do not always equal the `.desktop`
id (`QQ` runs as `com.qq.QQ`). The service resolves each id against the
installed entries the way the built-in taskbar does, pins the resolved
desktop id, and launches through the entry file itself.

## Usage

| Gesture | Effect |
| ------- | ------ |
| Left click | Focus the window, cycle a multi-window tile, or launch a pinned app |
| Middle click | Close the active window of the tile under the pointer |
| Right click | Open the window menu for the tile under the pointer |

## Settings

Plugin-level:

- **Pinned apps** - desktop entry IDs kept on the strip when they are not
  running. Seeded once from this setting, then owned by the pin action in the
  menu and persisted under the plugin data directory.

Widget-level: **Show all monitors**, **Only active workspace**, **Show running
windows**, **Icon scale**, **Item spacing**, **Pinned app opacity**, **Show
active indicator**, **Active indicator color**, **Active/inactive opacity**,
**Show window titles**, **Window title width**, **Taskbar maximum width**,
**Group by workspace**, **Hidden workspaces**, **Hide empty workspaces**, **One
icon per app in groups**, **Workspace group content**, **Workspace group
capsule**, **Active/inactive group border color**, **Show workspace labels**,
**Minimal workspace labels**, and the focused/occupied/empty/urgent workspace
colors.

## Notes

- The service publishes on `better-taskbar.state`; the widget and menu only read
  that snapshot.
- Workspace grouping needs per-window workspace data, which Umbriel reports.
- `prefer_symbolic_icons` is not exposed: the declarative `ui.image` control does
  not tint symbolic icons.
