"""scripts/install.sh: the notification events file (plan R1 T1.3).

The install path runs against a copy of the script and its assets in
``tmp_path``, with stub ``python3``, ``kpackagetool6`` and ``qtpaths6`` first on
PATH, so it never runs pip, never touches the real widget and never writes
outside the test's own HOME (the script deletes ``<checkout>/build``, which
here is the copy's).
"""

import configparser
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent.parent
INSTALL_SCRIPT = ROOT / "scripts" / "install.sh"
NOTIFYRC = ROOT / "assets" / "hearthside.notifyrc"
REQUIRED_QML = (
    "QtQuick/Layouts", "QtQuick/Dialogs", "QtCore", "org/kde/kirigami", "org/kde/kcmutils",
    "org/kde/plasma/plasma5support", "org/kde/plasma/components", "org/kde/plasma/extras",
    "org/kde/plasma/plasmoid",
)

# Answers exactly the python3 calls the install path makes; anything else exits 97.
PYTHON_STUB = """#!/bin/sh
case "$*" in
    "-c "*) exit 0 ;;
    "-m pip --version") exit 0 ;;
    "-m pip show ai-usage-kde") exit 1 ;;
    "-m pip install "*) exit 0 ;;
    "-P -m hearthside --version") echo 0.0-test ;;
    *) exit 97 ;;
esac
"""
KPACKAGETOOL_STUB = """#!/bin/sh
case "$1 $2 $3" in
    "-t Plasma/Applet -s") exit 1 ;;
    "-t Plasma/Applet -i") exit 0 ;;
    *) exit 97 ;;
esac
"""


def _stub(directory, name, text):
    path = directory / name
    path.write_text(text)
    path.chmod(0o755)


def _copied_project(tmp_path):
    project = tmp_path / "project"
    (project / "scripts").mkdir(parents=True)
    shutil.copy2(INSTALL_SCRIPT, project / "scripts" / "install.sh")
    shutil.copytree(ROOT / "assets", project / "assets")
    (project / "plasmoid").mkdir()
    return project


def run_install(tmp_path, *, xdg_data_home=None):
    project = _copied_project(tmp_path)
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    qml = tmp_path / "qml"
    for module in REQUIRED_QML + ("QtWebEngine",):
        (qml / module).mkdir(parents=True, exist_ok=True)
    stubs = tmp_path / "stub-bin"
    stubs.mkdir(exist_ok=True)
    _stub(stubs, "python3", PYTHON_STUB)
    _stub(stubs, "kpackagetool6", KPACKAGETOOL_STUB)
    _stub(stubs, "qtpaths6", f"#!/bin/sh\necho '{qml}'\n")
    env = {"PATH": f"{stubs}:/usr/bin:/bin", "HOME": str(home)}
    if xdg_data_home is not None:
        env["XDG_DATA_HOME"] = str(xdg_data_home)
    completed = subprocess.run(
        ["sh", str(project / "scripts" / "install.sh")],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=60, check=False,
    )
    return completed, home


def test_notifyrc_declares_the_component_and_both_alert_events():
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read_string(NOTIFYRC.read_text(encoding="utf-8"))
    assert {section: dict(parser[section]) for section in parser.sections()} == {
        "Global": {"IconName": "hearthside", "Comment": "Hearthside"},
        "Event/usageLow": {"Name": "Plan running low", "Action": "Popup"},
        "Event/usageReset": {"Name": "Plan reset", "Action": "Popup"},
    }


def test_install_script_passes_sh_n():
    completed = subprocess.run(["sh", "-n", str(INSTALL_SCRIPT)], capture_output=True, text=True, check=False)
    assert (completed.returncode, completed.stderr) == (0, "")


def test_install_copies_the_notifyrc_with_mode_0644(tmp_path):
    completed, home = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    installed = home / ".local" / "share" / "knotifications6" / "hearthside.notifyrc"
    assert installed.read_bytes() == NOTIFYRC.read_bytes()
    assert stat.S_IMODE(installed.stat().st_mode) == 0o644
    assert not installed.is_symlink()


def test_install_honours_xdg_data_home(tmp_path):
    data = tmp_path / "data"
    completed, home = run_install(tmp_path, xdg_data_home=data)
    assert completed.returncode == 0, completed.stderr
    assert (data / "knotifications6" / "hearthside.notifyrc").read_bytes() == NOTIFYRC.read_bytes()
    assert not (home / ".local" / "share" / "knotifications6").exists()


@pytest.mark.parametrize("old_mode", [0o600, 0o666])
def test_install_replaces_an_old_copy_and_resets_its_mode(tmp_path, old_mode):
    directory = tmp_path / "home" / ".local" / "share" / "knotifications6"
    directory.mkdir(parents=True)
    (directory / "hearthside.notifyrc").write_text("[Global]\n")
    (directory / "hearthside.notifyrc").chmod(old_mode)
    completed, _ = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert (directory / "hearthside.notifyrc").read_bytes() == NOTIFYRC.read_bytes()
    assert stat.S_IMODE((directory / "hearthside.notifyrc").stat().st_mode) == 0o644


def test_install_replaces_a_symlink_instead_of_writing_through_it(tmp_path):
    target = tmp_path / "precious"
    target.write_text("keep")
    directory = tmp_path / "home" / ".local" / "share" / "knotifications6"
    directory.mkdir(parents=True)
    (directory / "hearthside.notifyrc").symlink_to(target)
    completed, _ = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert target.read_text() == "keep"
    assert not (directory / "hearthside.notifyrc").is_symlink()
    assert (directory / "hearthside.notifyrc").read_bytes() == NOTIFYRC.read_bytes()


def test_install_writes_only_the_icon_and_the_notifyrc_under_home(tmp_path):
    completed, home = run_install(tmp_path)
    assert completed.returncode == 0, completed.stderr
    written = sorted(path.relative_to(home).as_posix() for path in home.rglob("*") if path.is_file())
    assert written == [
        ".local/share/icons/hicolor/scalable/apps/hearthside.svg",
        ".local/share/knotifications6/hearthside.notifyrc",
    ]
    assert sorted(os.listdir(tmp_path / "project")) == ["assets", "plasmoid", "scripts"]
