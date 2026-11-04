"""Read one text file dropped on the Chat tab (``--read-dropped HEX``, plan D63).

QML cannot read files, so for a single local ``file://`` drop it passes the
path's UTF-8 bytes hex-encoded (argv holds only ``[0-9a-f]``, nothing a shell
or argparse could misread). The reply is the file's text, never its path.

Only small regular text files are read: the last path component may not be a
symlink (``O_NOFOLLOW``), FIFOs, devices and directories are refused before
anything is opened (and ``O_NONBLOCK`` keeps a swapped-in FIFO from blocking),
and the size must be 1..131072 bytes, which also refuses ``/proc`` files
(they report size 0); files on the ``/proc`` and ``/sys`` filesystems are
refused by device too. The text must be strict UTF-8 without
NUL characters and at most 32000 characters. Runs no program, writes nothing.
"""

from __future__ import annotations

import errno
import os
import re
import stat
from typing import Optional

MAX_BYTES = 131072
MAX_CHARS = 32000
MAX_HEX = 8192
HEX_PATH = re.compile(r"(?:[0-9a-f]{2}){1,%d}" % (MAX_HEX // 2))

_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOCTTY


class DropError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def decode_path(value: str) -> Optional[bytes]:
    """The absolute path bytes from lowercase hex, or None when it is not one."""
    if not isinstance(value, str) or HEX_PATH.fullmatch(value) is None:
        return None
    path = bytes.fromhex(value)
    if not path.startswith(b"/") or b"\x00" in path:
        return None
    return path


def _open_error(error: OSError) -> DropError:
    if error.errno in (errno.ENOENT, errno.ENOTDIR):
        return DropError("absent")
    if error.errno in (errno.EACCES, errno.EPERM):
        return DropError("unreadable")
    if error.errno == errno.ELOOP:
        return DropError("not-file")
    return DropError("os-error")


# Kernel interfaces, never user files. /proc reports size 0 anyway, but sysfs
# attributes report 4096, so both are refused by device as well.
PSEUDO_ROOTS = ("/proc", "/sys")


def _pseudo_devices() -> set[int]:
    devices = set()
    try:
        root = os.stat("/").st_dev
    except OSError:
        return devices
    for path in PSEUDO_ROOTS:
        try:
            device = os.stat(path).st_dev
        except OSError:
            continue
        if device != root:  # Not mounted (a plain directory): nothing to refuse.
            devices.add(device)
    return devices


def _check_size(info: os.stat_result) -> None:
    if not stat.S_ISREG(info.st_mode) or info.st_size == 0 or info.st_dev in _pseudo_devices():
        raise DropError("not-file")
    if info.st_size > MAX_BYTES:
        raise DropError("too-large")


def read_text(path: bytes) -> str:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise _open_error(error) from None
    if stat.S_ISLNK(before.st_mode):
        raise DropError("not-file")
    _check_size(before)
    try:
        descriptor = os.open(path, _FLAGS)
    except OSError as error:
        raise _open_error(error) from None
    try:
        info = os.fstat(descriptor)
        if (info.st_dev, info.st_ino) != (before.st_dev, before.st_ino):
            raise DropError("not-file")  # Swapped between the check and the open.
        _check_size(info)
        data = b""
        # One byte more than the size: a file that grew meanwhile is refused.
        while len(data) <= info.st_size:
            chunk = os.read(descriptor, info.st_size + 1 - len(data))
            if not chunk:
                break
            data += chunk
    except OSError as error:
        raise _open_error(error) from None
    finally:
        os.close(descriptor)
    if len(data) > info.st_size or len(data) > MAX_BYTES:
        raise DropError("too-large")
    if not data:
        raise DropError("not-file")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise DropError("not-text") from None
    if "\x00" in text:
        raise DropError("not-text")
    if len(text) > MAX_CHARS:
        raise DropError("too-long")
    return text


def run(value: str) -> dict[str, object]:
    """CLI entry: ``{"ok":true,"text":...}`` or a bare error code."""
    path = decode_path(value)
    if path is None:
        return {"ok": False, "error": "not-file"}
    try:
        return {"ok": True, "text": read_text(path)}
    except DropError as error:
        return {"ok": False, "error": error.code}
    except OSError:
        return {"ok": False, "error": "os-error"}


__all__ = ["MAX_BYTES", "MAX_CHARS", "decode_path", "read_text", "run"]
