# Screen Keyboard

A US tenkeyless (87-key) on-screen keyboard for Wayland. It sends key events through a persistent virtual keyboard without taking keyboard focus, allowing applications and input methods to process input normally. Drag either side of the top toolbar to move the keyboard. The centered icons adjust position and size, clear selected modifiers, and hide the keyboard. Position and size are saved between sessions.

## Plugin ID and dependencies

- **Plugin ID:** `io.soloev/screen-keyboard`
- **Dependencies:** Python 3 (standard library only), Linux uinput, and read/write access to `/dev/uinput`.
- No `wdotool` or third-party Python packages are required.

## Plugin API

Requires Noctalia **plugin API 46**. Provides a bar widget (`button`), a Control Center shortcut (`toggle`), a background service (`service`), and keyboard/preview layers that do not take keyboard focus.
