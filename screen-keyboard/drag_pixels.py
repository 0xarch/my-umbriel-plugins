"""A static transparent pixel stream supplies native pointer capture to the grip."""

import array
import fcntl
import os
import socket
import stat
import struct
import threading


class DragPixels:
    def __init__(self, path):
        self.path = str(path)
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.buffer = None
        self.bound = False
        self.thread = None
        try:
            if os.path.lexists(self.path):
                info = os.lstat(self.path)
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
                    raise ValueError("Refusing to replace an unrelated drag socket")
                os.unlink(self.path)
            self.server.bind(self.path)
            self.bound = True
            os.chmod(self.path, 0o600)
            self.server.listen(4)
            self.server.settimeout(0.2)
            self.buffer = os.memfd_create("keyboard-drag", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
            os.write(self.buffer, b"\x00\x00\x00\x00")
            fcntl.fcntl(self.buffer, fcntl.F_ADD_SEALS,
                        fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW | fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SEAL)
            self.thread = threading.Thread(target=self.run, name="keyboard-drag", daemon=True)
            self.thread.start()
        except Exception:
            self.close()
            raise

    def run(self):
        while not self.stop.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with client:
                client.settimeout(0.2)
                try:
                    _, uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                    if uid != os.geteuid():
                        continue
                    hello = False
                    sent = False
                    while not self.stop.is_set():
                        try:
                            data = client.recv(32)
                        except socket.timeout:
                            continue
                        if len(data) != 8:
                            break
                        kind, argument = struct.unpack("<II", data)
                        if not hello:
                            if (kind, argument) != (1, 1):
                                break
                            client.sendmsg([struct.pack("<IIII", 1, 0, 1, 1)],
                                           [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [self.buffer]))])
                            hello = True
                        elif (kind, argument) == (2, 0):
                            if not sent:
                                client.sendall(struct.pack("<II", 2, 0))
                                sent = True
                            # Static image: after upload, the next REQUEST stays
                            # pending. No repeated frames, busy loop or GPU churn.
                        else:
                            break
                except OSError:
                    pass

    def close(self):
        self.stop.set()
        self.server.close()
        if self.thread is not None:
            self.thread.join(timeout=1)
        if self.buffer is not None:
            os.close(self.buffer)
            self.buffer = None
        if self.bound:
            os.unlink(self.path)
            self.bound = False
