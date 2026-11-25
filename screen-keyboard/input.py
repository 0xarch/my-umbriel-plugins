"""One persistent uinput keyboard. Never opens or records physical input devices."""

import contextlib
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import sys
import time

from drag_pixels import DragPixels


KEYS = set(range(1, 59)) | set(range(59, 71)) | {87, 88, 97, 99, 100, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 119, 125, 126, 127}
MODIFIERS = {29, 42, 54, 56, 97, 100, 125, 126}
EVENT = struct.Struct("@llHHi")


def event(fd, code, value):
    os.write(fd, EVENT.pack(0, 0, 1, code, value))
    os.write(fd, EVENT.pack(0, 0, 0, 0, 0))


def parse_request(request):
    if not isinstance(request, dict) or request.get("action") != "key":
        raise ValueError("Invalid key request")
    code = request.get("code")
    mods = request.get("mods", [])
    if type(code) is not int or code not in KEYS or code in MODIFIERS:
        raise ValueError("Unsupported key code")
    if not isinstance(mods, list) or len(mods) > 8:
        raise ValueError("Invalid modifiers")
    if any(type(key) is not int or key not in MODIFIERS for key in mods) or len(set(mods)) != len(mods):
        raise ValueError("Unsupported modifiers")
    return code, mods


def press(fd, code, mods):
    held = []
    try:
        for key in mods + [code]:
            held.append(key)
            event(fd, key, 1)
        time.sleep(0.012)
    finally:
        # Each click is a complete stroke; no modifier remains held between clicks.
        failure = None
        for key in reversed(held):
            try:
                event(fd, key, 0)
            except OSError as exc:
                failure = exc
        if failure is not None:
            raise failure


def message(value):
    print(json.dumps(value), flush=True)


def serve(path):
    directory = Path(path).parent
    info = directory.stat()
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise PermissionError("Keyboard data directory must be private and owned by this user")
    lock = os.open(str(path) + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    device = None
    bound = False
    pixels = None
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if os.path.lexists(path):
            info = os.lstat(path)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
                raise ValueError("Refusing to replace an unrelated socket path")
            os.unlink(path)
        device = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        fcntl.ioctl(device, 0x40045564, 1)  # UI_SET_EVBIT(EV_KEY)
        for code in sorted(KEYS):
            fcntl.ioctl(device, 0x40045565, code)  # UI_SET_KEYBIT
        # Legacy uinput_user_dev is a stable Linux ABI (80-byte name, input_id,
        # ff_effects_max, four ABS arrays). A US physical layout uses evdev codes.
        setup = struct.pack("=80sHHHHI256i", b"Noctalia Screen Keyboard", 0x03, 0x1209, 0x534b, 1, 0, *([0] * 256))
        os.write(device, setup)
        fcntl.ioctl(device, 0x5501)  # UI_DEV_CREATE
        server.bind(path)
        bound = True
        os.chmod(path, 0o600)
        server.listen(8)
        try:
            pixels = DragPixels(directory / "drag.sock")
        except Exception as exc:
            message({"event": "drag-error", "error": str(exc)})
        time.sleep(0.2)  # Allow libinput to discover this device before first use.
        message({"event": "ready", "drag_path": pixels.path if pixels is not None else None})
        while True:
            connection, _ = server.accept()
            with connection:
                connection.settimeout(2)
                try:
                    _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                    if uid != os.geteuid():
                        raise PermissionError("Peer uid mismatch")
                    data = bytearray()
                    while b"\n" not in data:
                        chunk = connection.recv(1024)
                        if not chunk:
                            raise ValueError("Incomplete request")
                        data.extend(chunk)
                        if len(data) > 2048:
                            raise ValueError("Request too large")
                    code, mods = parse_request(json.loads(data.split(b"\n", 1)[0]))
                    press(device, code, mods)
                    reply = {"ok": True}
                except Exception as exc:
                    reply = {"ok": False, "error": str(exc)}
                try:
                    connection.sendall((json.dumps(reply) + "\n").encode())
                except OSError:
                    pass
    finally:
        if pixels is not None:
            with contextlib.suppress(OSError):
                pixels.close()
        server.close()
        if device is not None:
            os.close(device)  # Closing destroys the virtual device and all its key state.
        if bound:
            os.unlink(path)
        os.close(lock)


def send(path, code, modifiers):
    request = {"action": "key", "code": int(code), "mods": [int(key) for key in modifiers]}
    parse_request(request)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(path)
        client.sendall((json.dumps(request) + "\n").encode())
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(1024)
            if not chunk or len(response) > 4096:
                raise ValueError("Invalid keyboard response")
            response.extend(chunk)
        value = json.loads(response.split(b"\n", 1)[0])
        message(value)
        return 0 if value.get("ok") is True else 1


def main():
    if len(sys.argv) < 3:
        raise ValueError("Expected serve SOCKET or send SOCKET CODE [MODIFIERS]")
    if sys.argv[1] == "serve" and len(sys.argv) == 3:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            serve(sys.argv[2])
        except Exception as exc:
            message({"event": "error", "error": str(exc)})
            return 1
        finally:
            message({"event": "stopped"})
        return 0
    if sys.argv[1] == "send" and len(sys.argv) >= 4:
        return send(sys.argv[2], sys.argv[3], sys.argv[4:])
    raise ValueError("Invalid command")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        message({"ok": False, "error": str(error)})
        sys.exit(1)
