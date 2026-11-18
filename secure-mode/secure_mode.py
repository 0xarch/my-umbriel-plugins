"""Private runtime symlink and atomic durable state; Linux, Python stdlib only.

The symlink's inode has no useful permission bits on Linux. Read-only means
0400 on its *target*, not chmod on the link. This is not a same-UID sandbox.
"""

import contextlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys


NAME = "secure-mode.toml"
STATE = "state"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


@contextlib.contextmanager
def directory(path):
    fd = os.open(path, DIRECTORY_FLAGS)
    try:
        yield fd
    finally:
        os.close(fd)


def owned_regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        raise ValueError("Expected an owned regular file with no hard links")
    return info


@contextlib.contextmanager
def private_dir(name, parent=None, create=True):
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("Directory must be owned by this user and private (0700): " + str(name))
        yield fd
    finally:
        os.close(fd)


def read_state(data):
    try:
        fd = os.open(STATE, os.O_RDONLY | FILE_FLAGS, dir_fd=data)
    except FileNotFoundError:
        return False
    with os.fdopen(fd, "r", encoding="ascii") as stream:
        owned_regular(stream.fileno())
        value = stream.read(32)
    if value not in ("enabled\n", "disabled\n"):
        raise ValueError("Damaged secure-mode state; preserved without applying changes")
    return value == "enabled\n"


def has_link(runtime, source):
    try:
        info = os.stat(NAME, dir_fd=runtime, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if not stat.S_ISLNK(info.st_mode) or info.st_uid != os.geteuid():
        raise ValueError("Runtime destination is not an owned managed symlink; refusing to replace it")
    if os.readlink(NAME, dir_fd=runtime) != str(source):
        raise ValueError("Runtime symlink has an unexpected target; refusing to replace it")
    return True


def protect_source(source):
    fd = os.open(source, os.O_RDONLY | FILE_FLAGS)
    try:
        owned_regular(fd)
        os.fchmod(fd, 0o400)
        os.fsync(fd)
    finally:
        os.close(fd)


def effective_state(runtime, source):
    if not has_link(runtime, source):
        return False
    fd = os.open(source, os.O_RDONLY | FILE_FLAGS)
    try:
        info = owned_regular(fd)
        return True if stat.S_IMODE(info.st_mode) == 0o400 else None
    finally:
        os.close(fd)


def change_link(runtime, source, enabled):
    present = has_link(runtime, source)
    if enabled and not present:
        os.symlink(str(source), NAME, dir_fd=runtime)
    elif not enabled and present:
        os.unlink(NAME, dir_fd=runtime)
    os.fsync(runtime)


def commit(data, runtime, source, enabled):
    """Stage durable state before touching the link; roll back on save failure.

    A process/power interruption between link and state commits is reconciled
    from the last atomic state file on the next restore.
    """
    previous = has_link(runtime, source)
    temporary = ".state-" + secrets.token_hex(12)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | FILE_FLAGS, 0o600, dir_fd=data)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write("enabled\n" if enabled else "disabled\n")
            stream.flush()
            os.fsync(stream.fileno())
        if enabled:
            protect_source(source)
        try:
            change_link(runtime, source, enabled)
            os.replace(temporary, STATE, src_dir_fd=data, dst_dir_fd=data)
        except Exception:
            change_link(runtime, source, previous)
            raise
        os.fsync(data)
    finally:
        try:
            os.unlink(temporary, dir_fd=data)
        except FileNotFoundError:
            pass


def reload_config():
    try:
        result = subprocess.run(
            ["umbriel", "msg", "config-reload"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("umbriel msg config-reload failed: " + str(exc)) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError("umbriel msg config-reload failed: " + (detail or "exit " + str(result.returncode)))


def apply(action, data_path, home, tmp_root="/tmp"):
    """Explicit roots are for isolated harness fixtures; CLI uses fixed roots."""
    source = Path(home) / ".config/umbriel" / NAME
    runtime = None
    with contextlib.ExitStack() as stack:
        try:
            if action not in ("restore", "on", "off"):
                raise ValueError("Unknown secure-mode action")
            # Never follow a pre-planted symlink in /tmp or relax another
            # directory's permissions. All subsequent mutations are fd-relative.
            tmp = stack.enter_context(directory(tmp_root))
            parent = stack.enter_context(private_dir("io.soloev", tmp))
            runtime = stack.enter_context(private_dir("secure-mode", parent))
            lock = os.open(".lock", os.O_RDWR | os.O_CREAT | FILE_FLAGS, 0o600, dir_fd=runtime)
            stack.callback(os.close, lock)
            owned_regular(lock)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = stack.enter_context(private_dir(str(data_path), create=False))
            saved = read_state(data)
            enabled = saved if action == "restore" else action == "on"
            has_link(runtime, source)  # Reject unrelated destinations before any mutation or reload.
            failure = None
            try:
                commit(data, runtime, source, enabled)
            except Exception as exc:
                failure = exc
            # Reload only after all writes/cleanup/rollback have finished, while
            # still holding the lock. Also reconcile an unchanged startup restore.
            try:
                reload_config()
            except Exception as exc:
                if failure is not None:
                    raise RuntimeError(str(failure) + "; " + str(exc)) from exc
                raise
            if failure is not None:
                raise failure
            return {"ok": True, "enabled": enabled}
        except Exception as exc:
            actual = None
            if runtime is not None:
                try:
                    actual = effective_state(runtime, source)
                except (OSError, ValueError):
                    pass
            return {"ok": False, "enabled": actual, "error": str(exc)}


def main():
    if len(sys.argv) != 3 or not os.environ.get("HOME"):
        result = {"ok": False, "enabled": None, "error": "Expected action, plugin data directory and HOME"}
    else:
        result = apply(sys.argv[1], sys.argv[2], os.environ["HOME"])
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
