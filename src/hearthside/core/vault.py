"""Passphrase-encrypted folder for the Chat tab's saved sign-ins (gocryptfs).

Layout: the cipher directory is ``$XDG_DATA_HOME/hearthside/vault/`` and the
plaintext view is mounted at ``$XDG_RUNTIME_DIR/hearthside/vault/`` (tmpfs, so
anything written after an unmount lands in RAM, never on disk).

The passphrase never passes through this process. gocryptfs runs kdialog
itself (``-extpass``) and reads the answer from kdialog's stdout. Changing the
passphrase hands the second kdialog's stdout to gocryptfs's stdin through a
pipe whose ends this process only holds, never reads. Every child gets an
argv list with no shell and stdin/stdout/stderr on /dev/null. The exceptions
are those pipe ends and the version line of ``gocryptfs -version``. Streams
must be /dev/null: the gocryptfs daemon keeps whatever it inherited until
unmount, so a pipe would block its reader (Plasma's DataSource) for hours.

A mount is trusted only after ``/proc/self/mountinfo`` shows our gocryptfs
mount of our cipher directory, owned by us and without ``allow_other``.
Replies are short state or error codes: never paths, names or counts.
"""

from __future__ import annotations

import errno
import fcntl
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from collections.abc import Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Callable, Optional

from .webdata import (
    APP_DIR,
    PRIVATE_MODE,
    WEB_DIR,
    HelperError,
    _close,
    _descriptors,
    _require_safe_rmtree,
    data_base,
    open_base,
    open_child_dir,
    remove_entry,
)

OPERATIONS = ("status", "create", "unlock", "lock", "change-passphrase", "destroy")
VAULT_DIR = "vault"
LOCK_FILE = "vault.lock"
# Holds only the first -passwd dialog's exit status (see extpass_relay.py).
PASSWD_MARKER = "passwd.status"
RELAY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extpass_relay.py")
CONF_FILE = "gocryptfs.conf"
MOUNTINFO = "/proc/self/mountinfo"
# Non-interactive operations give up on a held lock after this long ("busy").
LOCK_TIMEOUT = 5.0
_POLL_INTERVAL = 0.1
_TOOL_TIMEOUT = 30.0
_WOULD_BLOCK = {errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES}


# =====================================================================================
# gocryptfs CONTRACT, measured against gocryptfs 2.6.1 (spike SP2, 2026-10-31). Flags,
# argv framing, exit codes, the -passwd flow and the mountpoint mode live in this block
# and nowhere else.
# =====================================================================================

# Tools that must all be found on PATH. "gocryptfs-v2" is reported when gocryptfs
# exists but `gocryptfs -version` does not say v2 or later.
TOOLS = ("gocryptfs", "kdialog", "fusermount3")
VERSION_ARGS = ("-version",)
VERSION_PREFIX = b"gocryptfs v"
MINIMUM_MAJOR = 2

# The bare mountpoint must be 0700 when mounting: fusermount3 refuses 0500 (exit 19,
# "no write access") and 0300 (exit 10). It is reset to 0700 under the vault lock right
# before each mount and sealed to 0500 after every unmount, so nothing can write into
# the tmpfs directory while the folder is locked.
MOUNTPOINT_MODE = 0o700
SEALED_MODE = 0o500

# Fixed English kdialog prompts (D26). None may start with "-".
TITLE = "Hearthside"
PROMPT_CREATE = (
    "Choose a passphrase for the Hearthside encrypted chat folder. "
    "If you forget it, the saved chat data cannot be recovered."
)
PROMPT_UNLOCK = "Enter the passphrase for the Hearthside encrypted chat folder."
PROMPT_CURRENT = "Enter the current passphrase for the Hearthside encrypted chat folder."
PROMPT_NEW = "Choose a new passphrase for the Hearthside encrypted chat folder."

# Allow-list of the dash arguments each gocryptfs phase may pass, checked before every
# run; everything else (key material, -ko/-o mount options, -config, -fsname, debug
# output, ...) is refused. "-version" is only ever the sole argument.
PHASE_FLAGS = {
    "init": frozenset({"-init", "-q", "-extpass"}),
    "mount": frozenset({"-q", "-nosyslog", "-extpass"}),
    "passwd": frozenset({"-passwd", "-q", "-extpass"}),
}
# Positional arguments (absolute paths) per phase: the cipher dir, plus the mountpoint.
PHASE_POSITIONALS = {"init": 1, "mount": 2, "passwd": 1}

# gocryptfs exit code -> error code, per operation; anything unlisted gets the
# operation's fallback. Measured: 12 wrong passphrase; 9 cancelled, and also an
# empty passphrase (22 was never seen, so empty is reported as "cancelled");
# 10 mountpoint missing, not empty or unreadable; 6 cipher dir missing, or on
# -init not empty / already initialised (extpass not called); 11 no
# gocryptfs.conf; 19 fusermount3 refused, or already mounted ("busy" when a
# mount is present afterwards, see _mount).
EXIT_CODES = {
    "init": {6: "exists", 9: "cancelled"},
    "mount": {6: "absent", 9: "cancelled", 10: "mount-failed", 11: "absent", 12: "wrong-passphrase",
              19: "mount-failed"},
    "passwd": {6: "absent", 9: "cancelled", 11: "absent", 12: "wrong-passphrase"},
}
EXIT_FALLBACK = {"init": "init-failed", "mount": "mount-failed", "passwd": "os-error"}
EXIT_ALREADY_MOUNTED = 19

# gocryptfs -passwd calls extpass ONCE, for the old passphrase (with stdin on
# /dev/null), then reads the new one as a single line from its own stdin; no
# confirmation, a second line is ignored. A wrong old passphrase exits 12 without
# reading stdin; an empty or closed stdin exits 9. So the old one comes from
# kdialog --password through extpass_relay.py, and only after that dialog has
# exited does kdialog --newpassword start, writing into gocryptfs's stdin.
# After a correct-looking first answer gocryptfs still needs a moment to check it:
# wait this long for an early exit (wrong passphrase) before opening the second
# dialog; a later exit closes that dialog again.
PASSWD_GRACE = 1.0

# Lock: plain `fusermount3 -u`, never -z. WebEngine releases its files about a
# second after the chat profile is destroyed (SP1), so a busy unmount is retried
# after these delays, then reported as "busy". The lazy unmount of plan D24 stays
# an unimplemented fallback: SP1 showed it is not needed, and the helper cannot
# tell its own widget's leftover files from another widget's live chat.
UNMOUNT_RETRY_DELAYS = (0.5, 1.0)


def extpass_args(program: str, *arguments: str) -> list[str]:
    """``-extpass <arg>`` for the program and each of its arguments.

    Each argument is its own argv element. Because there are several, gocryptfs
    does not split them on spaces. gocryptfs turns every single-dash argument
    into a double-dash one ("dash duplication"), so a value like ``-X`` would
    arrive as ``--X``; such values are refused.
    """
    result = []
    for argument in (program, *arguments):
        if _single_dash(argument):
            raise HelperError("os-error")
        result += ["-extpass", argument]
    return result


def _single_dash(argument: str) -> bool:
    return argument.startswith("-") and not argument.startswith("--")


def init_argv(gocryptfs: str, kdialog: str, cipher: str) -> list[str]:
    # Without -q, -init prints the master key on stdout; -q silences it and stdout is
    # /dev/null anyway (D22).
    return [gocryptfs, "-init", "-q", *extpass_args(kdialog, "--title", TITLE, "--newpassword", PROMPT_CREATE), cipher]


def mount_argv(gocryptfs: str, kdialog: str, cipher: str, mountpoint: str) -> list[str]:
    return [
        gocryptfs, "-q", "-nosyslog",
        *extpass_args(kdialog, "--title", TITLE, "--password", PROMPT_UNLOCK),
        cipher, mountpoint,
    ]


def passwd_argv(gocryptfs: str, python: str, marker: str, kdialog: str, cipher: str) -> list[str]:
    """``gocryptfs -passwd``; its extpass is the relay running the old-passphrase dialog."""
    relay = extpass_args(python, RELAY, marker, kdialog, "--title", TITLE, "--password", PROMPT_CURRENT)
    return [gocryptfs, "-passwd", "-q", *relay, cipher]


def new_passphrase_argv(kdialog: str) -> list[str]:
    """The second -passwd dialog; its stdout is gocryptfs's stdin."""
    return [kdialog, "--title", TITLE, "--newpassword", PROMPT_NEW]


def unmount_argv(fusermount: str, mountpoint: str) -> list[str]:
    return [fusermount, "-u", mountpoint]


def exit_error(phase: str, code: int) -> str:
    return EXIT_CODES[phase].get(code, EXIT_FALLBACK[phase])


# =====================================================================================
# End of the gocryptfs contract.
# =====================================================================================


@dataclass(frozen=True)
class Context:
    tools: dict[str, str]
    missing: tuple[str, ...]
    data_base: str
    cipher: str
    runtime: str
    mountpoint: str


@dataclass(frozen=True)
class MountEntry:
    mountpoint: str
    mount_options: tuple[str, ...]
    fstype: str
    source: str
    super_options: tuple[str, ...]


# --- children ---------------------------------------------------------------------------


def _gocryptfs_phase(arguments: Sequence[str]) -> str:
    if "-init" in arguments:
        return "init"
    if "-passwd" in arguments:
        return "passwd"
    return "mount"


def _check_gocryptfs_argv(arguments: Sequence[str]) -> None:
    if list(arguments) == list(VERSION_ARGS):
        return
    phase = _gocryptfs_phase(arguments)
    allowed = PHASE_FLAGS[phase]
    positionals = 0
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        index += 1
        if argument == "-extpass":
            # A dialog argument (a path or prompt), not a gocryptfs flag; it must not
            # start with a single dash (dash duplication).
            if index >= len(arguments) or _single_dash(arguments[index]):
                raise HelperError("os-error")
            index += 1
            continue
        if argument.startswith("-"):
            if argument not in allowed:
                raise HelperError("os-error")
            continue
        if not os.path.isabs(argument):
            raise HelperError("os-error")
        positionals += 1
    if positionals != PHASE_POSITIONALS[phase]:
        raise HelperError("os-error")


def _check_argv(argv: Sequence[str]) -> None:
    """Refuse any child argv that is not one of the contract's shapes (defence in depth).

    gocryptfs gets only its phase's allow-listed flags; fusermount3 only ``-u
    <mountpoint>``; kdialog only the new-passphrase dialog (the other dialogs run
    as ``-extpass`` values). No argument outside an ``-extpass`` value may
    contain ``allow_``, wherever it sits.
    """
    if not argv or not os.path.isabs(argv[0]):
        raise HelperError("os-error")
    tool = os.path.basename(argv[0])
    arguments = list(argv[1:])
    plain = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-extpass" and tool == "gocryptfs":
            index += 2
            continue
        plain.append(arguments[index])
        index += 1
    if any("allow_" in argument for argument in plain):
        raise HelperError("os-error")
    if tool == "gocryptfs":
        _check_gocryptfs_argv(arguments)
    elif tool == "fusermount3":
        if len(arguments) != 2 or arguments[0] != "-u" or not os.path.isabs(arguments[1]):
            raise HelperError("os-error")
    elif tool == "kdialog":
        if arguments != new_passphrase_argv(argv[0])[1:]:
            raise HelperError("os-error")
    else:
        raise HelperError("os-error")


def _run(argv: Sequence[str], *, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
         timeout: Optional[float] = None) -> int:
    """Run one child: argv list, no shell, stderr always on /dev/null."""
    _check_argv(argv)
    try:
        completed = subprocess.run(
            list(argv),
            stdin=stdin,
            stdout=stdout,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise HelperError("os-error") from None
    except OSError:
        raise HelperError("missing-tool") from None
    return completed.returncode


def _spawn(argv: Sequence[str], *, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
           env: Optional[Mapping[str, str]] = None) -> subprocess.Popen:
    """Start one child without waiting: argv list, no shell, stderr on /dev/null."""
    _check_argv(argv)
    try:
        return subprocess.Popen(
            list(argv),
            stdin=stdin,
            stdout=stdout,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            env=None if env is None else dict(env),
        )
    except OSError:
        raise HelperError("missing-tool") from None


def relay_environment(environ: Optional[Mapping[str, str]] = None) -> dict[str, str]:
    """The environment for ``gocryptfs -passwd``, inherited by the Python relay.

    gocryptfs starts the relay as a plain script, so no ``-I``: every ``PYTHON*``
    variable is dropped (no PYTHONPATH, PYTHONSTARTUP, PYTHONHOME, ...), the
    user site directory stays off ``sys.path`` and so does the script's own
    directory (``PYTHONSAFEPATH``, Python 3.11+).
    """
    values = os.environ if environ is None else environ
    clean = {key: value for key, value in values.items() if not key.startswith("PYTHON")}
    clean["PYTHONNOUSERSITE"] = "1"
    clean["PYTHONSAFEPATH"] = "1"
    return clean


def _stop(child: subprocess.Popen) -> None:
    """Close a dialog that is no longer wanted; reap it either way."""
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=_TOOL_TIMEOUT)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def _gocryptfs_major(gocryptfs: str) -> int:
    """Major version from ``gocryptfs -version`` (0 when unknown).

    The version line is read from a private pipe; it holds no user data.
    """
    reader, writer = os.pipe()
    try:
        try:
            code = _run([gocryptfs, *VERSION_ARGS], stdout=writer, timeout=_TOOL_TIMEOUT)
        finally:
            os.close(writer)
            writer = -1
        if code != 0:
            return 0
        os.set_blocking(reader, False)
        try:
            head = os.read(reader, 256)
        except BlockingIOError:
            return 0
    except HelperError:
        return 0
    finally:
        _close(reader)
        _close(writer)
    if not head.startswith(VERSION_PREFIX):
        return 0
    digits = head[len(VERSION_PREFIX):].split(b".", 1)[0]
    return int(digits) if digits.isdigit() else 0


def _find_tools() -> tuple[dict[str, str], tuple[str, ...]]:
    found: dict[str, str] = {}
    missing: list[str] = []
    for name in TOOLS:
        path = shutil.which(name)
        if path and os.path.isabs(path):
            found[name] = path
        else:
            missing.append(name)
        # A relative PATH entry gives a relative result: treated as not found above.
        if name == "gocryptfs" and name in found and _gocryptfs_major(found[name]) < MINIMUM_MAJOR:
            missing.append("gocryptfs-v2")
    return found, tuple(missing)


# --- paths --------------------------------------------------------------------------------


def runtime_dir(environ: Optional[Mapping[str, str]] = None) -> str:
    """``$XDG_RUNTIME_DIR`` when it is absolute, a real directory, ours and 0700."""
    values = os.environ if environ is None else environ
    value = values.get("XDG_RUNTIME_DIR") or ""
    if not value or not os.path.isabs(value):
        raise HelperError("no-runtime-dir")
    try:
        info = os.lstat(value)
    except OSError:
        raise HelperError("no-runtime-dir") from None
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise HelperError("no-runtime-dir")
    return os.path.realpath(value)


def context(environ: Optional[Mapping[str, str]] = None, *, find_tools: bool = True) -> Context:
    tools, missing = _find_tools() if find_tools else ({}, ())
    runtime = runtime_dir(environ)
    base = os.path.realpath(data_base(environ))
    return Context(
        tools=tools,
        missing=missing,
        data_base=base,
        cipher=os.path.join(base, APP_DIR, VAULT_DIR),
        runtime=runtime,
        mountpoint=os.path.join(runtime, APP_DIR, VAULT_DIR),
    )


def _require_tools(ctx: Context, *names: str) -> None:
    wanted = names or TOOLS
    if any(name not in ctx.tools for name in wanted) or (
        "gocryptfs" in wanted and "gocryptfs-v2" in ctx.missing
    ):
        raise HelperError("missing-tool")


# --- lock -----------------------------------------------------------------------------------


@contextmanager
def _runtime_app_dir(ctx: Context) -> Iterator[int]:
    with _descriptors() as opened:
        runtime = open_base(ctx.runtime, create=False)
        if runtime is None:
            raise HelperError("no-runtime-dir")
        opened.append(runtime)
        app = open_child_dir(runtime, APP_DIR, create=True)
        opened.append(app)
        yield app


@contextmanager
def vault_lock(
    ctx: Context,
    *,
    wait: bool = False,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> Iterator[int]:
    """Hold ``$XDG_RUNTIME_DIR/hearthside/vault.lock``; yields that directory's fd.

    With ``wait`` it blocks as long as needed (an unlock dialog may be open in
    another widget); otherwise a lock held past ``LOCK_TIMEOUT`` gives "busy".
    """
    with _runtime_app_dir(ctx) as app:
        flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            descriptor = os.open(LOCK_FILE, flags, 0o600, dir_fd=app)
        except OSError as error:
            raise (HelperError("symlink") if error.errno == errno.ELOOP else HelperError("os-error")) from None
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise HelperError("not-directory" if stat.S_ISDIR(info.st_mode) else "os-error")
            if info.st_uid != os.getuid():
                raise HelperError("not-owned")
            if wait:
                fcntl.flock(descriptor, fcntl.LOCK_EX)
            else:
                deadline = monotonic() + LOCK_TIMEOUT
                while True:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except OSError as error:
                        if error.errno not in _WOULD_BLOCK:
                            raise HelperError("os-error") from None
                    if monotonic() >= deadline:
                        raise HelperError("busy")
                    sleep(_POLL_INTERVAL)
            yield app
        finally:
            _close(descriptor)


# --- mountinfo -----------------------------------------------------------------------------


def _unescape(field: str) -> str:
    """Undo the kernel's octal escapes (``\\040`` space, ``\\011``, ``\\012``, ``\\134``)."""
    out = []
    index = 0
    while index < len(field):
        chunk = field[index:index + 4]
        if len(chunk) == 4 and chunk[0] == "\\" and all(c in "01234567" for c in chunk[1:]):
            out.append(chr(int(chunk[1:], 8)))
            index += 4
        else:
            out.append(field[index])
            index += 1
    return "".join(out)


def parse_mountinfo(text: str) -> list[MountEntry]:
    entries = []
    for line in text.splitlines():
        fields = line.split(" ")
        try:
            separator = fields.index("-", 6)
        except ValueError:
            continue
        if len(fields) < separator + 4:
            continue
        entries.append(MountEntry(
            mountpoint=_unescape(fields[4]),
            mount_options=tuple(fields[5].split(",")),
            fstype=fields[separator + 1],
            source=_unescape(fields[separator + 2]),
            super_options=tuple(fields[separator + 3].split(",")),
        ))
    return entries


def mount_entry(mountpoint: str) -> Optional[MountEntry]:
    """The top-most mount at ``mountpoint``, or None."""
    try:
        with open(MOUNTINFO, encoding="utf-8", errors="surrogateescape") as handle:
            text = handle.read()
    except OSError:
        raise HelperError("os-error") from None
    found = None
    for entry in parse_mountinfo(text):
        if entry.mountpoint == mountpoint:
            found = entry
    return found


def entry_is_ours(entry: MountEntry, ctx: Context) -> bool:
    options = set(entry.super_options) | set(entry.mount_options)
    return (
        entry.fstype == "fuse.gocryptfs"
        and entry.source == ctx.cipher
        and f"user_id={os.getuid()}" in entry.super_options
        and not any(option.split("=", 1)[0] in {"allow_other", "allow_root"} for option in options)
    )


def _open_mount_root(app: int) -> int:
    """Open the mountpoint below ``app``; raises OSError (ENOTCONN when stale)."""
    return os.open(VAULT_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=app)


def _same_device(root: os.stat_result, parent: os.stat_result) -> bool:
    return root.st_dev == parent.st_dev


def _verified_root(ctx: Context, app: int, entry: MountEntry) -> int:
    """An fd for the mount root after every check passed; else not-verified."""
    if not entry_is_ours(entry, ctx):
        raise HelperError("not-verified")
    try:
        root = _open_mount_root(app)
    except OSError as error:
        if error.errno == errno.ENOTCONN:
            raise HelperError("stale-mount") from None
        raise HelperError("not-verified") from None
    try:
        info = os.fstat(root)
        parent = os.fstat(app)
    except OSError:
        _close(root)
        raise HelperError("not-verified") from None
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or _same_device(info, parent)
    ):
        _close(root)
        raise HelperError("not-verified")
    return root


# --- state ------------------------------------------------------------------------------------


def _cipher_state(ctx: Context) -> str:
    """"locked" (gocryptfs.conf is there), "absent" (no or an empty cipher dir) or "damaged".

    "damaged" is a cipher dir that holds files but no regular gocryptfs.conf:
    gocryptfs can neither open it nor -init it, only destroy can clear it.
    """
    with _descriptors() as opened:
        parent = open_base(ctx.data_base, create=False)
        if parent is None:
            return "absent"
        opened.append(parent)
        for name in (APP_DIR, VAULT_DIR):
            parent = open_child_dir(parent, name, create=False)
            if parent is None:
                return "absent"
            opened.append(parent)
        try:
            info = os.stat(CONF_FILE, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        except OSError:
            raise HelperError("os-error") from None
        if info is not None and stat.S_ISLNK(info.st_mode):
            raise HelperError("symlink")
        if info is not None and stat.S_ISREG(info.st_mode):
            return "locked"
        try:
            empty = info is None and not os.listdir(parent)
        except OSError:
            raise HelperError("os-error") from None
        return "absent" if empty else "damaged"


def _unmount(ctx: Context) -> int:
    fusermount = ctx.tools.get("fusermount3")
    if fusermount is None:
        raise HelperError("missing-tool")
    return _run(unmount_argv(fusermount, ctx.mountpoint), timeout=_TOOL_TIMEOUT)


def _seal_mountpoint(ctx: Context, app: int) -> None:
    """Make the bare (unmounted) mountpoint 0500; best effort.

    Only when nothing is mounted there: a chmod on a live mount would change the
    encrypted folder's root instead.
    """
    try:
        if mount_entry(ctx.mountpoint) is not None:
            return
        descriptor = open_child_dir(app, VAULT_DIR, create=False)
    except HelperError:
        return
    if descriptor is None:
        return
    try:
        os.fchmod(descriptor, SEALED_MODE)
    except OSError:
        pass
    finally:
        _close(descriptor)


def _clean_stale(ctx: Context, app: int) -> None:
    """Unmount a dead gocryptfs mount (its daemon died with plasmashell)."""
    if "fusermount3" not in ctx.tools:
        raise HelperError("stale-mount")
    if _unmount(ctx) != 0 or mount_entry(ctx.mountpoint) is not None:
        raise HelperError("stale-mount")
    _seal_mountpoint(ctx, app)


def _is_stale(app: int) -> bool:
    try:
        descriptor = _open_mount_root(app)
    except OSError as error:
        return error.errno == errno.ENOTCONN
    _close(descriptor)
    return False


def settle(ctx: Context, app: int) -> str:
    """Current state ("absent", "locked", "unlocked", "damaged"), cleaning up a stale mount.

    Must run under ``vault_lock``. A mount that fails verification raises
    not-verified; nothing may use it.
    """
    entry = mount_entry(ctx.mountpoint)
    if entry is not None:
        if _is_stale(app):
            _clean_stale(ctx, app)
        else:
            _close(_verified_root(ctx, app, entry))
            return "unlocked"
    return _cipher_state(ctx)


@contextmanager
def verified_mount(environ: Optional[Mapping[str, str]] = None) -> Iterator[int]:
    """Yield an fd for the verified, unlocked mount root, holding the vault lock.

    Runs no tool: a stale or foreign mount is simply not-verified.
    """
    ctx = context(environ, find_tools=False)
    with vault_lock(ctx) as app:
        entry = mount_entry(ctx.mountpoint)
        if entry is None or _is_stale(app):
            raise HelperError("not-verified")
        root = _verified_root(ctx, app, entry)
        try:
            yield root
        finally:
            _close(root)


# --- operations --------------------------------------------------------------------------------


def status(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    if ctx.missing:
        return {"ok": True, "state": "unavailable", "missing": list(ctx.missing)}
    with vault_lock(ctx) as app:
        return {"ok": True, "state": settle(ctx, app)}


# Leftovers the bare mountpoint may hold: profile folders a widget's chat created in
# the tmpfs directory after another widget locked the folder under it.
_LEFTOVER_PROFILE = re.compile(r"applet-(0|[1-9][0-9]*)-g(0|[1-9][0-9]*)")


def _leftover_profiles(mountpoint: int) -> Optional[list[str]]:
    """Names below ``web/`` when that is all the bare mountpoint holds, else None."""
    try:
        if os.listdir(mountpoint) != [WEB_DIR]:
            return None
        web = open_child_dir(mountpoint, WEB_DIR, create=False)
    except (HelperError, OSError):
        return None
    if web is None:
        return None
    try:
        names = os.listdir(web)
        for name in names:
            if _LEFTOVER_PROFILE.fullmatch(name) is None:
                return None
            info = os.stat(name, dir_fd=web, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                return None
    except OSError:
        return None
    finally:
        _close(web)
    return names


def _clear_leftovers(mountpoint: int) -> None:
    """Delete ``web/applet-*`` leftovers from the bare mountpoint; anything else: mount-failed.

    Runs under the vault lock with nothing mounted, so these are tmpfs files
    written after a lock, never the encrypted folder's contents. Every entry is
    checked before any is deleted; nothing is followed.
    """
    names = _leftover_profiles(mountpoint)
    if names is None:
        raise HelperError("mount-failed")
    _require_safe_rmtree()
    with _descriptors() as opened:
        web = open_child_dir(mountpoint, WEB_DIR, create=False)
        if web is None:
            raise HelperError("mount-failed")
        opened.append(web)
        for name in names:
            remove_entry(web, name)
    try:
        os.rmdir(WEB_DIR, dir_fd=mountpoint)
        if os.listdir(mountpoint):
            raise HelperError("mount-failed")
    except OSError:
        raise HelperError("mount-failed") from None


def _prepare_mountpoint(app: int) -> None:
    descriptor = open_child_dir(app, VAULT_DIR, create=True, mode=MOUNTPOINT_MODE)
    try:
        if os.listdir(descriptor):
            _clear_leftovers(descriptor)
    except OSError:
        raise HelperError("os-error") from None
    finally:
        _close(descriptor)


def _mount(ctx: Context, app: int) -> None:
    # Under the vault lock, right before mounting: 0700 (a sealed 0500 one is reset).
    _prepare_mountpoint(app)
    code = _run(mount_argv(ctx.tools["gocryptfs"], ctx.tools["kdialog"], ctx.cipher, ctx.mountpoint))
    if code != 0:
        mounted = mount_entry(ctx.mountpoint) is not None
        if not mounted:
            _seal_mountpoint(ctx, app)
        if code == EXIT_ALREADY_MOUNTED and mounted:
            raise HelperError("busy")
        raise HelperError(exit_error("mount", code))
    entry = mount_entry(ctx.mountpoint)
    if entry is None:
        _seal_mountpoint(ctx, app)
        raise HelperError("mount-failed")
    try:
        _close(_verified_root(ctx, app, entry))
    except HelperError:
        # Never leave an unverified mount behind.
        try:
            if _unmount(ctx) == 0:
                _seal_mountpoint(ctx, app)
        except HelperError:
            pass
        raise HelperError("not-verified") from None


def _make_cipher_dir(ctx: Context) -> bool:
    """Create the empty cipher dir; True when this call created it."""
    with _descriptors() as opened:
        base = open_base(ctx.data_base, create=True)
        opened.append(base)
        app = open_child_dir(base, APP_DIR, create=True)
        opened.append(app)
        try:
            os.stat(VAULT_DIR, dir_fd=app, follow_symlinks=False)
            created = False
        except FileNotFoundError:
            created = True
        except OSError:
            raise HelperError("os-error") from None
        cipher = open_child_dir(app, VAULT_DIR, create=True)
        opened.append(cipher)
        return created


def _forget_cipher_dir(ctx: Context) -> None:
    """Remove the cipher dir again after a failed -init, only if still empty."""
    with _descriptors() as opened:
        base = open_base(ctx.data_base, create=False)
        if base is None:
            return
        opened.append(base)
        app = open_child_dir(base, APP_DIR, create=False)
        if app is None:
            return
        opened.append(app)
        try:
            os.rmdir(VAULT_DIR, dir_fd=app)
        except OSError:
            pass


def create(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    _require_tools(ctx)
    with vault_lock(ctx, wait=True) as app:
        state = settle(ctx, app)
        if state == "damaged":
            raise HelperError("damaged")
        if state != "absent":
            raise HelperError("exists")
        created = _make_cipher_dir(ctx)
        code = _run(init_argv(ctx.tools["gocryptfs"], ctx.tools["kdialog"], ctx.cipher))
        if code != 0:
            if created:
                _forget_cipher_dir(ctx)
            raise HelperError(exit_error("init", code))
        _mount(ctx, app)
    return {"ok": True}


def unlock(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    _require_tools(ctx)
    with vault_lock(ctx, wait=True) as app:
        state = settle(ctx, app)
        if state in ("absent", "damaged"):
            raise HelperError(state)
        if state == "locked":
            _mount(ctx, app)
    return {"ok": True}


def lock(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    with vault_lock(ctx) as app:
        entry = mount_entry(ctx.mountpoint)
        if entry is None:
            _seal_mountpoint(ctx, app)
            return {"ok": True}
        if _is_stale(app):
            _clean_stale(ctx, app)
            return {"ok": True}
        if not entry_is_ours(entry, ctx):
            raise HelperError("not-verified")
        for delay in (*UNMOUNT_RETRY_DELAYS, None):
            if _unmount(ctx) == 0 and mount_entry(ctx.mountpoint) is None:
                _seal_mountpoint(ctx, app)
                return {"ok": True}
            if delay is None:
                break
            time.sleep(delay)
        # Still in use (another widget's chat, open files): never forced.
        raise HelperError("busy")


def _clear_marker(app: int) -> None:
    for name in (PASSWD_MARKER, PASSWD_MARKER + ".tmp"):
        try:
            os.unlink(name, dir_fd=app)
        except FileNotFoundError:
            pass
        except OSError:
            raise HelperError("os-error") from None


def _read_marker(app: int) -> Optional[int]:
    """The first dialog's exit status once the relay published it, else None.

    The marker holds a number written by extpass_relay.py, never a passphrase.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        descriptor = os.open(PASSWD_MARKER, flags, dir_fd=app)
    except FileNotFoundError:
        return None
    except OSError:
        raise HelperError("os-error") from None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise HelperError("os-error")
        head = os.read(descriptor, 8).strip()
    except OSError:
        raise HelperError("os-error") from None
    finally:
        _close(descriptor)
    return int(head) if head.isdigit() else None


def _first_dialog_status(app: int, child: subprocess.Popen) -> Optional[int]:
    """Wait for the old-passphrase dialog to exit; None when gocryptfs exited first."""
    while child.poll() is None:
        status = _read_marker(app)
        if status is not None:
            return status
        time.sleep(_POLL_INTERVAL)
    return None


def _exited_within(child: subprocess.Popen, seconds: float) -> bool:
    try:
        child.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        return False
    return True


def _passwd(ctx: Context, app: int) -> int:
    """Run ``gocryptfs -passwd``; returns its exit code.

    1. gocryptfs starts with stdin = the pipe's read end. Its extpass (the
       relay) shows kdialog --password; the old passphrase goes from kdialog's
       stdout to gocryptfs directly.
    2. Once the relay reports that dialog exited OK, and gocryptfs is still
       running after PASSWD_GRACE (it exits at once on a wrong passphrase),
       kdialog --newpassword starts with stdout = the pipe's write end.
    3. This process closes its copy of the write end, so a cancelled second
       dialog gives gocryptfs EOF (exit 9). It never reads the pipe.
    """
    python = sys.executable
    if not python or not os.path.isabs(python) or not os.path.isfile(RELAY):
        raise HelperError("missing-tool")
    marker = os.path.join(ctx.runtime, APP_DIR, PASSWD_MARKER)
    argv = passwd_argv(ctx.tools["gocryptfs"], python, marker, ctx.tools["kdialog"], ctx.cipher)
    _check_argv(argv)
    _clear_marker(app)
    reader, writer = os.pipe()
    child: Optional[subprocess.Popen] = None
    dialog: Optional[subprocess.Popen] = None
    try:
        child = _spawn(argv, stdin=reader, env=relay_environment())
        os.close(reader)
        reader = -1
        status = _first_dialog_status(app, child)
        if status == 0 and not _exited_within(child, PASSWD_GRACE):
            dialog = _spawn(new_passphrase_argv(ctx.tools["kdialog"]), stdout=writer)
        os.close(writer)
        writer = -1
        code = child.wait()
    finally:
        _close(reader)
        _close(writer)
        if dialog is not None:
            # gocryptfs is done (or failed early): a dialog still open is useless.
            _stop(dialog)
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        _clear_marker(app)
    return code


def change_passphrase(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    _require_tools(ctx, "gocryptfs", "kdialog")
    with vault_lock(ctx, wait=True) as app:
        state = settle(ctx, app)
        if state in ("absent", "damaged"):
            raise HelperError(state)
        if state != "locked":
            raise HelperError("not-locked")
        code = _passwd(ctx, app)
        if code != 0:
            raise HelperError(exit_error("passwd", code))
    return {"ok": True}


def destroy(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    ctx = context(environ)
    _require_safe_rmtree()
    with vault_lock(ctx) as app:
        if settle(ctx, app) == "unlocked":
            raise HelperError("not-locked")
        with _descriptors() as opened:
            base = open_base(ctx.data_base, create=False)
            data_app = None if base is None else open_child_dir(base, APP_DIR, create=False)
            opened.extend(fd for fd in (base, data_app) if fd is not None)
            if data_app is not None:
                remove_entry(data_app, VAULT_DIR)
        # Not mounted (checked above), so this is the bare tmpfs mountpoint.
        remove_entry(app, VAULT_DIR)
    return {"ok": True}


# --- purge (scripts/install.sh --uninstall-web-data) -------------------------------------------

# What purge may delete below $XDG_DATA_HOME/hearthside, in reply order: the
# encrypted folder's ciphertext. Saved sign-ins exist nowhere else (there is no
# unencrypted store), so this is the only category.
PURGE_CATEGORIES = (VAULT_DIR,)
# Where systemd puts XDG_RUNTIME_DIR; also checked when the variable is unset
# (e.g. install.sh run from a TTY), so a live mount is never missed.
DEFAULT_RUNTIME = "/run/user/{uid}"


def _purge_runtimes(environ: Optional[Mapping[str, str]]) -> list[str]:
    runtimes = []
    for values in (environ, {"XDG_RUNTIME_DIR": DEFAULT_RUNTIME.format(uid=os.getuid())}):
        try:
            runtime = runtime_dir(values)
        except HelperError:
            continue
        if runtime not in runtimes:
            runtimes.append(runtime)
    return runtimes


def _vault_mounted(cipher_paths: set[str], mountpoints: set[str]) -> bool:
    """Any mount (ours, foreign or stale) at our mountpoint or of our cipher dir."""
    try:
        with open(MOUNTINFO, encoding="utf-8", errors="surrogateescape") as handle:
            text = handle.read()
    except OSError:
        raise HelperError("os-error") from None
    return any(
        entry.mountpoint in mountpoints or entry.source in cipher_paths
        for entry in parse_mountinfo(text)
    )


def _purge_tree(environ: Optional[Mapping[str, str]], runtimes: list[str]) -> list[str]:
    base_path = data_base(environ)
    cipher_paths = {
        os.path.join(base, APP_DIR, VAULT_DIR) for base in (base_path, os.path.realpath(base_path))
    }
    mountpoints = {os.path.join(runtime, APP_DIR, VAULT_DIR) for runtime in runtimes}
    if _vault_mounted(cipher_paths, mountpoints):
        raise HelperError("not-locked")
    with _descriptors() as opened:
        base = open_base(base_path, create=False)
        if base is None:
            return []
        opened.append(base)
        app = open_child_dir(base, APP_DIR, create=False)
        if app is None:
            return []
        opened.append(app)
        # Check every category before deleting any: a symlink, file or foreign
        # directory in the way refuses the whole purge.
        present = []
        for name in PURGE_CATEGORIES:
            child = open_child_dir(app, name, create=False)
            if child is not None:
                _close(child)
                present.append(name)
        for name in present:
            remove_entry(app, name)
        try:
            os.rmdir(APP_DIR, dir_fd=base)
        except OSError:
            pass  # Not empty or already gone: leave it.
        return present


def purge(environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    """Delete the encrypted folder (every saved chat sign-in is inside it).

    Refuses while anything is mounted at the vault mountpoint or from the
    cipher dir. Runs no tool. The reply names only the deleted categories.
    """
    try:
        _require_safe_rmtree()
        runtimes = _purge_runtimes(environ)
        if not runtimes:
            return {"ok": True, "removed": _purge_tree(environ, runtimes)}
        # Hold the vault lock so an unlock in another widget cannot race us.
        values = os.environ if environ is None else environ
        ctx = context({**values, "XDG_RUNTIME_DIR": runtimes[0]}, find_tools=False)
        with vault_lock(ctx):
            return {"ok": True, "removed": _purge_tree(environ, runtimes)}
    except HelperError as error:
        return {"ok": False, "error": error.code}
    except OSError:
        return {"ok": False, "error": "os-error"}


_HANDLERS: dict[str, Callable[[Optional[Mapping[str, str]]], dict[str, object]]] = {
    "status": status,
    "create": create,
    "unlock": unlock,
    "lock": lock,
    "change-passphrase": change_passphrase,
    "destroy": destroy,
}


def run(operation: str, environ: Optional[Mapping[str, str]] = None) -> dict[str, object]:
    """CLI entry: a reply object that never contains a path or name."""
    handler = _HANDLERS.get(operation)
    if handler is None:
        raise ValueError("Unsupported vault operation.")
    try:
        return handler(environ)
    except HelperError as error:
        return {"ok": False, "error": error.code}
    except OSError:
        return {"ok": False, "error": "os-error"}


__all__ = ["OPERATIONS", "PRIVATE_MODE", "purge", "run", "status", "verified_mount"]
