"""QML files must not redeclare built-in Item properties.

Qt 6.12 marks some Item properties FINAL (e.g. ``baseline``); declaring a
property with that name makes the whole file fail to load in plasmashell
("Cannot override FINAL property"), which qmllint does not report.
"""

import re
from pathlib import Path

UI = Path(__file__).resolve().parent.parent / "plasmoid" / "contents" / "ui"
TESTS_QML = Path(__file__).resolve().parent / "qml"

# QQuickItem / QObject property names (Qt 6).
ITEM_PROPERTIES = {
    "parent", "children", "data", "resources", "x", "y", "z", "width", "height",
    "implicitWidth", "implicitHeight", "opacity", "enabled", "visible",
    "visibleChildren", "states", "transitions", "state", "childrenRect", "anchors",
    "left", "right", "horizontalCenter", "top", "bottom", "verticalCenter",
    "baseline", "baselineOffset", "clip", "focus", "activeFocus",
    "activeFocusOnTab", "focusPolicy", "rotation", "scale", "transformOrigin",
    "transformOriginPoint", "transform", "smooth", "antialiasing", "layer",
    "containmentMask", "objectName",
}

DECLARATION = re.compile(r"^\s*(?:required\s+|readonly\s+|default\s+)*property\s+[\w.<>]+\s+(\w+)", re.M)


def test_no_qml_file_redeclares_an_item_property():
    offenders = []
    for path in sorted(list(UI.glob("*.qml")) + list(TESTS_QML.glob("*.qml"))):
        for name in DECLARATION.findall(path.read_text(encoding="utf-8")):
            if name in ITEM_PROPERTIES:
                offenders.append(f"{path.name}: {name}")
    assert offenders == []


def test_the_check_catches_the_original_bug():
    sample = '    ColumnLayout {\n        property string baseline: ""\n    }\n'
    assert [n for n in DECLARATION.findall(sample) if n in ITEM_PROPERTIES] == ["baseline"]
