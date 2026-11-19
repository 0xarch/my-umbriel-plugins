# Buttons

Editable function drawer on your desktop.

`io.soloev/buttons`, requires Noctalia plugin API 46。

## Usage

Add Buttons component to your bar and click to open. Also supports opening from Control Center.

IPC：`noctalia msg panel-toggle io.soloev/buttons:drawer`。

Edit your own item in the panel. Note that it is not automatically saved during editing.

### Focus Mode

Focus Mode will hide the edit buttons, also hide pager if only there's only one page of buttons. Press `Ctrl+E` to switch to editing mode.

### Card Status

Each item can have a status by enabling status mode.

Read `stdout` and expected **only one line** with the following format:

```sh
0
1
0 $icon
1 $icon
```

If line starts with `1`, the card will become "activated", and if it's `0` then deactivated.

If optional icon name is passed, the card's icon will switch to that one.

