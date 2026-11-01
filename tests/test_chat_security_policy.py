"""Static checks for the Chat tab's privacy policy (docs/privacy.md, "Chat tab").

The Chat tab hosts provider websites in Qt WebEngine inside plasmashell. Its
top constraint is that nothing the user enters reaches disk, logs, argv, env
or the plasmoid config. These tests scan the plasmoid sources for the rules
that keep it that way. Comments are stripped before searching, so a comment
that names a forbidden API cannot fail a test, while real code still does.
String literals are kept: a forbidden name inside a string (for example in
``Qt.createQmlObject``) is still a real use.
"""

import ast
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest


PLASMOID = Path(__file__).resolve().parent.parent / "plasmoid"
CONTENTS = PLASMOID / "contents"
UI = CONTENTS / "ui"
MAIN_XML = CONTENTS / "config" / "main.xml"
CHAT_SITES_JS = UI / "ChatSites.js"
CHAT_STORAGE_JS = UI / "ChatStorage.js"
CHAT_WEB_VIEW = UI / "ChatWebView.qml"
CHAT_VIEW = UI / "ChatView.qml"
FULL_REPRESENTATION = UI / "FullRepresentation.qml"
MAIN_QML = UI / "main.qml"
CONFIG_PAGES = (UI / "configGeneral.qml", UI / "configChat.qml")
OLLAMA_CHAT_JS = UI / "OllamaChat.js"
OLLAMA_CHAT_VIEW = UI / "OllamaChatView.qml"
SRC = PLASMOID.parent / "src" / "hearthside"
PORT_OWNER_PY = SRC / "core" / "portowner.py"
CLI_PY = SRC / "cli.py"
# Files of the built-in Ollama chat that are written in later plan phases.
# Rules about them skip while the file does not exist and enforce once it does.
PHASED_FILES = {"OllamaChat.js": "T1", "OllamaChatView.qml": "T4"}
# Chat files that may read the plasmoid config but never write it. Only the
# settings pages persist chat values (and main.qml the profile generation).
CHAT_CONFIG_READ_ONLY_FILES = (
    "ChatSites.js", "ChatStorage.js", "ChatView.qml", "ChatWebView.qml", "FullRepresentation.qml",
    "OllamaChat.js", "OllamaChatView.qml",
)
KCFG_NS = "{http://www.kde.org/standards/kcfg/1.0}"

EXPECTED_SITE_IDS = ["claude", "chatgpt", "grok", "gemini", "copilot", "mscopilot", "local"]
# Sites enabled for a fresh widget. Local is off until the user turns it on.
EXPECTED_DEFAULT_SITE_IDS = ["claude", "chatgpt", "grok", "gemini", "copilot", "mscopilot"]
LOCAL_SITE_ID = "local"
# Name, type and exact default of every persisted chat key.
CHAT_CONFIG_KEYS = {
    "chatSites": ("String", None),
    "chatDefaultSite": ("String", None),
    "chatCustomUrls": ("String", "{}"),
    "chatSignInStorage": ("String", "memory"),
    "chatProfileGeneration": ("Int", "0"),
}
# The Ollama address (plan T4). Expected once main.xml has it or the Ollama
# view exists, so it can neither be half-added nor forgotten.
OLLAMA_CONFIG_KEYS = {"chatOllamaUrl": ("String", "http://127.0.0.1:11434")}
# Keys that existed before the Chat tab. Anything else in main.xml would be a
# new persisted value; the Chat tab may only persist the keys above.
PRE_CHAT_CONFIG_KEYS = {
    "trackedProviders", "panelProviders", "providerMetrics", "usageMode",
    "refreshInterval", "configSchemaVersion", "initialSetupComplete",
}

# Characters after which a "/" starts a regex literal rather than division.
_REGEX_PRECEDERS = set("(,=:[!&|?{};+-*%<>~^")
_REGEX_KEYWORDS = ("return", "typeof", "case", "do", "else", "in", "of", "void", "new", "delete")


def _strip_comments(source, blank_strings=False):
    """Replace // and /* */ comments in QML/JS with spaces.

    String, template and regex literals are skipped so "https://..." is not
    mistaken for a comment. Newlines and offsets are preserved, so positions
    and line numbers in the result match the original file. With
    ``blank_strings`` the contents of string literals are blanked too, which
    makes brace matching safe.
    """
    out = list(source)
    length = len(source)
    index = 0
    last_significant = ""

    def blank(start, end, keep_delimiters=False):
        lo, hi = (start + 1, end - 1) if keep_delimiters else (start, end)
        for pos in range(lo, hi):
            if out[pos] != "\n":
                out[pos] = " "

    def regex_allowed():
        if last_significant == "" or last_significant in _REGEX_PRECEDERS:
            return True
        tail = "".join(source[max(0, index - 8):index]).rstrip()
        return any(
            tail.endswith(word) and (len(tail) == len(word) or not (tail[-len(word) - 1].isalnum() or tail[-len(word) - 1] == "_"))
            for word in _REGEX_KEYWORDS
        )

    while index < length:
        char = source[index]
        nxt = source[index + 1] if index + 1 < length else ""
        if char == "/" and nxt == "/":
            end = source.find("\n", index)
            end = length if end == -1 else end
            blank(index, end)
            index = end
            continue
        if char == "/" and nxt == "*":
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            blank(index, end)
            index = end
            continue
        if char in "\"'`":
            end = index + 1
            while end < length and source[end] != char:
                if source[end] == "\\":
                    end += 1
                elif source[end] == "\n" and char != "`":
                    break
                end += 1
            end = min(end + 1, length)
            if blank_strings:
                blank(index, end, keep_delimiters=True)
            last_significant = char
            index = end
            continue
        if char == "/" and regex_allowed():
            end = index + 1
            in_class = False
            while end < length and source[end] != "\n":
                current = source[end]
                if current == "\\":
                    end += 2
                    continue
                if current == "[":
                    in_class = True
                elif current == "]":
                    in_class = False
                elif current == "/" and not in_class:
                    break
                end += 1
            if end < length and source[end] == "/":
                end += 1
                while end < length and source[end].isalpha():
                    end += 1
                if blank_strings:
                    blank(index, end, keep_delimiters=True)
                last_significant = "/"
                index = end
                continue
        if not char.isspace():
            last_significant = char
        index += 1
    return "".join(out)


def _read_code(path):
    assert path.is_file(), f"{path.relative_to(PLASMOID.parent)} is missing"
    return _strip_comments(path.read_text(encoding="utf-8"))


def _require_phased(path):
    """Skip a rule about a not-yet-written Ollama file; enforce once it exists."""
    if path.name in PHASED_FILES and not path.is_file():
        pytest.skip(f"{path.name} is not written yet (plan task {PHASED_FILES[path.name]}); "
                    "this rule enforces as soon as the file exists")


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def _hits(pattern, text):
    return [_line_of(text, match.start()) for match in re.finditer(pattern, text)]


def _rel(path):
    return path.relative_to(PLASMOID.parent).as_posix()


def _code_files():
    return sorted(
        path for path in PLASMOID.rglob("*")
        if path.is_file() and path.suffix in {".qml", ".js"}
    )


def _text_files():
    return sorted(
        path for path in PLASMOID.rglob("*")
        if path.is_file() and path.suffix in {".json", ".xml", ".desktop"}
    )


def _blocks(code, opener):
    """Yield the text of each ``opener`` block, e.g. ``WebEngineProfile {``.

    ``opener`` is a regex that must end at the opening brace or at a handler
    colon followed by a function/arrow/brace body.
    """
    blanked = _strip_comments(code, blank_strings=True)
    for match in re.finditer(opener, blanked):
        start = blanked.find("{", match.end() - 1)
        if start == -1:
            continue
        depth = 0
        for index in range(start, len(blanked)):
            if blanked[index] == "{":
                depth += 1
            elif blanked[index] == "}":
                depth -= 1
                if depth == 0:
                    yield match.start(), code[start:index + 1]
                    break


def _sites_literal(source):
    match = re.search(r"\b(?:var|let|const)\s+sites\s*=\s*\[", source)
    assert match, "ChatSites.js must declare `var sites = [ ... ]` as an array literal"
    start = match.end() - 1
    blanked = _strip_comments(source, blank_strings=True)
    depth = 0
    for index in range(start, len(blanked)):
        if blanked[index] in "[{":
            depth += 1
        elif blanked[index] in "]}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("ChatSites.js: unterminated `sites` array literal")


def _chat_site_ids():
    literal = _sites_literal(_read_code(CHAT_SITES_JS))
    # Only top-level site objects: the id key directly follows "{" or ",".
    return re.findall(r"""[{,]\s*["']?id["']?\s*:\s*["']([^"']+)["']""", literal)


def _site_objects(literal):
    """Return the source text of each top-level ``{ ... }`` in the sites array."""
    blanked = _strip_comments(literal, blank_strings=True)
    objects = []
    depth = 0
    start = -1
    for index, char in enumerate(blanked):
        if char in "[{":
            depth += 1
            if char == "{" and depth == 2:
                start = index
        elif char in "]}":
            if char == "}" and depth == 2:
                objects.append(literal[start:index + 1])
            depth -= 1
    return objects


def _site_key(site, key):
    """The string literal value of a top-level ``key`` in one site object, or None."""
    match = re.search(rf"""[{{,]\s*["']?{key}["']?\s*:\s*["']([^"']*)["']""", site)
    return match.group(1) if match else None


def _chat_sites():
    literal = _sites_literal(_read_code(CHAT_SITES_JS))
    sites = {}
    for site in _site_objects(literal):
        site_id = _site_key(site, "id")
        assert site_id, f"{_rel(CHAT_SITES_JS)}: every site object needs a literal id"
        sites[site_id] = site
    return sites


def _key_hits(site, key, allowed):
    """Snippets where ``key`` is set to anything other than the ``allowed`` literal."""
    return re.findall(rf"""[{{,]\s*["']?{key}["']?\s*:(?!\s*{allowed}\b)\s*[^,\n}}]*""", site)


def _main_xml_entries():
    assert MAIN_XML.is_file(), f"{_rel(MAIN_XML)} is missing"
    root = ET.parse(MAIN_XML).getroot()
    entries = {}
    for group in root.iter(f"{KCFG_NS}group"):
        for entry in group.iter(f"{KCFG_NS}entry"):
            default = entry.find(f"{KCFG_NS}default")
            entries[entry.get("name")] = {
                "group": group.get("name"),
                "type": entry.get("type"),
                "default": None if default is None else default.text,
            }
    return entries


# --- the comment stripper itself -------------------------------------------


def test_strip_comments_removes_comments_but_keeps_code_and_strings():
    source = (
        "// storageName: \"x\"\n"
        "/* runJavaScript(\"a\")\n console.log(1) */\n"
        "property string u: \"https://claude.ai/new\" // trailing console.log\n"
        "var r = /\\s*QtWebEngine\\/\\S+/g; var q = /[/]\"/;\n"
        "view.runJavaScript(\"1\")\n"
        "storageName: \"real\"\n"
    )
    stripped = _strip_comments(source)
    assert len(stripped) == len(source)
    assert stripped.count("\n") == source.count("\n")
    assert "\"https://claude.ai/new\"" in stripped
    assert "console" not in stripped
    assert _hits(r"\brunJavaScript\b", stripped) == [6]
    assert _hits(r"\bstorageName\b", stripped) == [7]


# --- imports ----------------------------------------------------------------


@pytest.mark.parametrize(
    ("module_pattern", "module"),
    [(r"QtWebEngine", "QtWebEngine"), (r"QtQuick\.Dialogs", "QtQuick.Dialogs")],
)
def test_webengine_and_dialogs_are_imported_only_by_chat_web_view(module_pattern, module):
    pattern = rf"\bimport\s+{module_pattern}\b"
    offenders = [
        f"{_rel(path)}:{line}"
        for path in _code_files() if path != CHAT_WEB_VIEW
        for line in _hits(pattern, _read_code(path))
    ]
    assert not offenders, f"{module} may only be imported by ChatWebView.qml; found in {offenders}"
    assert _hits(pattern, _read_code(CHAT_WEB_VIEW)), f"{_rel(CHAT_WEB_VIEW)} must import {module}"


def test_chat_sites_js_has_no_imports():
    code = _read_code(CHAT_SITES_JS)
    lines = _hits(r"(?m)^\s*(?:\.import\b|import\b)", code) + _hits(r"\bQt\.include\s*\(", code)
    assert not lines, f"{_rel(CHAT_SITES_JS)} must stay a pure library without imports; lines {lines}"


# --- the one profile: private by default, saved sign-ins only behind the gate ---------
#
# Rule checkers take source text so the "proof" tests below can feed them a
# violating copy of the real file and show that each rule really fails.

# Bindings of the profile, exactly, in this order (spike result 7: the paths
# before storageName and offTheRecord last, else Qt creates a stray folder
# under plasmashell's own data directory).
PROFILE_BINDINGS = (
    ("persistentStoragePath", r'chatWeb\.staySignedIn\s*\?\s*chatWeb\.storagePath\s*:\s*""'),
    ("cachePath", r'chatWeb\.staySignedIn\s*\?\s*chatWeb\.storagePath\s*:\s*""'),
    ("storageName", r'chatWeb\.staySignedIn\s*\?\s*chatWeb\.profileName\s*:\s*""'),
    ("httpCacheType", r"WebEngineProfile\.MemoryHttpCache"),
    ("persistentCookiesPolicy",
     r"chatWeb\.staySignedIn\s*\?\s*WebEngineProfile\.AllowPersistentCookies"
     r"\s*:\s*WebEngineProfile\.NoPersistentCookies"),
    ("persistentPermissionsPolicy", r"WebEngineProfile\.PersistentPermissionsPolicy\.AskEveryTime"),
    ("spellCheckEnabled", r"false"),
    ("offTheRecord", r"!\s*chatWeb\.staySignedIn"),
)
# Names that may appear only once each, inside the profile block.
PROFILE_ONLY_NAMES = ("storageName", "persistentStoragePath", "cachePath", "offTheRecord",
                      "AllowPersistentCookies")

FORBIDDEN_STORAGE = {
    "offTheRecord: false": r"\boffTheRecord\s*:\s*false\b",
    "defaultProfile": r"\bdefaultProfile\b",
    "ForcePersistentCookies": r"\bForcePersistentCookies\b",
    "DiskHttpCache": r"\bDiskHttpCache\b",
    "WebEngineProfilePrototype": r"\bWebEngineProfilePrototype\b",
    # A live switch of a profile crashes Qt WebEngine (spike result 6).
    "live profile assignment": r"\.\s*(?:offTheRecord|storageName|persistentStoragePath|cachePath"
                               r"|persistentCookiesPolicy|httpCacheType)\s*=(?!=)",
}


def _profile_problems(code):
    profiles = list(_blocks(code, r"\bWebEngineProfile\s*\{"))
    if len(profiles) != 1:
        return [f"exactly one WebEngineProfile expected, found {len(profiles)}"]
    _, body = profiles[0]
    inner = _strip_comments(body[1:-1], blank_strings=True)
    # Top-level property bindings only (depth 0 inside the block), handlers skipped.
    names = []
    depth = 0
    for line_start in [0] + [m.end() for m in re.finditer(r"\n", inner)]:
        line = inner[line_start:inner.find("\n", line_start) if "\n" in inner[line_start:] else len(inner)]
        if depth == 0:
            match = re.match(r"\s*(\w+)\s*:", line)
            if match and not match.group(1).startswith("on") and match.group(1) != "id":
                names.append(match.group(1))
        depth += line.count("{") - line.count("}")
    problems = []
    expected = [name for name, _ in PROFILE_BINDINGS]
    if names != expected:
        problems.append(f"profile bindings must be exactly {expected} in that order, got {names}")
    for name, value in PROFILE_BINDINGS:
        found = re.findall(rf"(?m)^\s*{name}\s*:\s*((?:[^\n]|\n\s*[?:])+)", body)
        if len(found) != 1 or not re.fullmatch(rf"\s*{value}\s*", found[0]):
            problems.append(f"{name} must be exactly `{value}`, got {found}")
    for name in PROFILE_ONLY_NAMES:
        total = len(_hits(rf"\b{name}\b", code))
        inside = len(_hits(rf"\b{name}\b", body))
        if total != inside or inside != 1:
            problems.append(f"{name} must appear once, inside the profile block ({inside} inside, {total} total)")
    return problems


def test_chat_web_view_declares_one_profile_in_the_safe_order():
    problems = _profile_problems(_read_code(CHAT_WEB_VIEW))
    assert not problems, f"{_rel(CHAT_WEB_VIEW)}: {problems}"


def _storage_offenders(sources):
    return [
        f"{name}:{line} {rule}"
        for name, code in sources.items()
        for rule, pattern in FORBIDDEN_STORAGE.items()
        for line in _hits(pattern, code)
    ] + [
        f"{name}:{line} {word}"
        for name, code in sources.items() if not name.endswith("ChatWebView.qml")
        for word in PROFILE_ONLY_NAMES
        for line in _hits(rf"\b{word}\b", code)
    ]


def _all_code():
    return {_rel(path): _read_code(path) for path in _code_files()}


def test_no_plasmoid_file_uses_forbidden_webengine_storage():
    offenders = _storage_offenders(_all_code())
    assert not offenders, f"forbidden or out-of-place WebEngine storage: {offenders}"


def _web_view_inputs_problems(code):
    problems = []
    for name, kind, default in (("staySignedIn", "bool", "false"),
                                ("storagePath", "string", '""'),
                                ("profileName", "string", '""')):
        declared = re.findall(rf"(?m)^\s*property\s+(\w+)\s+{name}\s*:\s*(.+?)\s*$", code)
        if declared != [(kind, default)]:
            problems.append(f"`property {kind} {name}: {default}` expected once, got {declared}")
        assigned = _hits(rf"(?<![\w.]){name}\s*=(?!=)|\.\s*{name}\s*=(?!=)", code)
        if assigned:
            problems.append(f"{name} must never be assigned inside ChatWebView (lines {assigned})")
    return problems


def test_chat_web_view_profile_inputs_default_to_private():
    problems = _web_view_inputs_problems(_read_code(CHAT_WEB_VIEW))
    assert not problems, f"{_rel(CHAT_WEB_VIEW)}: {problems}"


# ChatView is the only place that hands the profile inputs to ChatWebView,
# and only through the Loader's initial properties.
CHAT_VIEW_GATE = (
    r'readonly\s+property\s+bool\s+encrypted\s*:\s*'
    r'ChatStorage\.normalizeMode\(\s*chatView\.storageMode\s*\)\s*===\s*"encrypted"',
    r'readonly\s+property\s+bool\s+persistentReady\s*:\s*chatView\.encrypted\s*&&\s*'
    r'chatView\.storageReady\s*&&\s*chatView\.storagePath\s*!==\s*""\s*&&\s*'
    r'chatView\.profileName\s*!==\s*""',
    r"staySignedIn\s*:\s*chatView\.persistentReady\s*,",
    r'storagePath\s*:\s*chatView\.persistentReady\s*\?\s*chatView\.storagePath\s*:\s*""',
    r'profileName\s*:\s*chatView\.persistentReady\s*\?\s*chatView\.profileName\s*:\s*""',
    r'property\s+url\s+webSource\s*:\s*Qt\.resolvedUrl\(\s*"ChatWebView\.qml"\s*\)',
)


def _chat_view_gate_problems(code):
    problems = [f"missing `{pattern}`" for pattern in CHAT_VIEW_GATE if len(re.findall(pattern, code)) != 1]
    if len(_hits(r"\bstaySignedIn\s*:", code)) != 1:
        problems.append("staySignedIn may be set exactly once (in setSource)")
    if len(_hits(r"\bwebLoader\.setSource\s*\(\s*chatView\.webSource\s*,", code)) != 1 \
            or len(_hits(r"\bsetSource\s*\(", code)) != 1:
        problems.append("the web view must be created by exactly one webLoader.setSource(chatView.webSource, ...)")
    loaders = [body for _, body in _blocks(code, r"\bLoader\s*\{")]
    if len(loaders) != 1 or not re.search(r"\bactive\s*:\s*false\b", loaders[0]) \
            or re.search(r"\b(?:source|sourceComponent)\s*:", loaders[0]):
        problems.append("the one Loader must start `active: false` with no source binding")
    return problems


def test_persistent_profile_only_behind_the_verified_gate():
    problems = _chat_view_gate_problems(_read_code(CHAT_VIEW))
    assert not problems, f"{_rel(CHAT_VIEW)}: {problems}"


def _stay_signed_in_elsewhere(sources):
    return [
        f"{name}:{line}"
        for name, code in sources.items()
        if not name.endswith(("ChatView.qml", "ChatWebView.qml"))
        for line in _hits(r"\bstaySignedIn\s*[:=](?!=)", code)
    ]


def test_stay_signed_in_is_set_only_by_chat_view():
    offenders = _stay_signed_in_elsewhere(_all_code())
    assert not offenders, f"staySignedIn may only be set by ChatView.qml: {offenders}"


# main.qml: ready only when the helper reported the folder unlocked and said
# ok to prepare for this exact generation.
MAIN_READY = (
    r'readonly\s+property\s+bool\s+chatStorageReady\s*:\s*root\.chatStorageMode\s*===\s*"encrypted"\s*'
    r'&&\s*root\.chatVaultState\s*===\s*"unlocked"\s*&&\s*!root\.chatVaultHold\s*'
    r'&&\s*root\.chatPreparedGeneration\s*===\s*root\.chatGeneration\s*'
    r'&&\s*root\.chatProfilePath\s*!==\s*""\s*&&\s*root\.chatProfileName\s*!==\s*""'
)


def _main_ready_problems(code, full_representation):
    problems = []
    if len(re.findall(MAIN_READY, code)) != 1:
        problems.append("chatStorageReady must keep the exact verified-unlocked gate")
    if not re.search(
            r'readonly\s+property\s+string\s+chatStorageMode\s*:\s*'
            r'ChatStorage\.normalizeMode\(\s*Plasmoid\.configuration\.chatSignInStorage\s*\)', code):
        problems.append("chatStorageMode must be ChatStorage.normalizeMode(chatSignInStorage)")
    granted = [match for match in re.finditer(r"\bchatPreparedGeneration\s*=(?!=)(?!\s*-1\b)", code)]
    if len(granted) != 1:
        problems.append(f"chatPreparedGeneration may be set to a generation exactly once, got {len(granted)}")
    else:
        before = code[max(0, granted[0].start() - 400):granted[0].start()]
        if 'case "prepare"' not in before or not re.search(r"if\s*\(\s*reply\.ok\s*&&", before):
            problems.append("chatPreparedGeneration may only be granted in the prepare reply after reply.ok")
    if len(_hits(r"(?m)\bstorageReady\s*:\s*root\.chatStorageReady\s*$", full_representation)) != 1:
        problems.append("FullRepresentation must pass storageReady: root.chatStorageReady")
    if _hits(r"\bstorageReady\s*:", full_representation) != _hits(r"\bstorageReady\s*:\s*root\.chatStorageReady\b",
                                                                   full_representation):
        problems.append("storageReady may only be bound to root.chatStorageReady")
    return problems


def test_main_grants_saved_sign_ins_only_after_a_verified_prepare():
    problems = _main_ready_problems(_read_code(MAIN_QML), _read_code(FULL_REPRESENTATION))
    assert not problems, f"{_rel(MAIN_QML)}: {problems}"


def test_every_web_view_uses_the_chat_profile():
    code = _read_code(CHAT_WEB_VIEW)
    views = _hits(r"\bWebEngineView\s*\{", code)
    bindings = re.findall(r"\bprofile\s*:\s*([\w.]+)", code)
    wrong = [value for value in bindings if value != "chatProfile"]
    assert views, f"{_rel(CHAT_WEB_VIEW)} declares no WebEngineView"
    assert not wrong, f"{_rel(CHAT_WEB_VIEW)}: every `profile:` must be chatProfile, got {wrong}"
    assert len(bindings) >= len(views), (
        f"{_rel(CHAT_WEB_VIEW)}: {len(views)} WebEngineView declarations (lines {views}) "
        f"but only {len(bindings)} `profile: chatProfile` bindings"
    )


def test_chat_starts_only_in_the_open_popup():
    # A web view built while Plasma preloads the closed popup stays blank, and
    # no web engine should start before Chat is actually shown.
    # With the Ollama view, the web chat must also stay off while Ollama is shown.
    problems = _chat_view_current_problems(_read_code(FULL_REPRESENTATION), OLLAMA_CHAT_VIEW.is_file())
    assert not problems, f"{_rel(FULL_REPRESENTATION)}: {problems}"


CHAT_VIEW_CURRENT = r"(?m)^\s*current\s*:\s*full\.onChat\s*&&\s*root\.expanded\s*$"
CHAT_VIEW_CURRENT_OLLAMA = (
    r'(?m)^\s*current\s*:\s*full\.onChat\s*&&\s*root\.expanded\s*&&\s*root\.chatSiteId\s*!==\s*"ollama"\s*$'
)


def _chat_view_current_problems(code, with_ollama):
    plain = len(_hits(CHAT_VIEW_CURRENT, code))
    gated = len(_hits(CHAT_VIEW_CURRENT_OLLAMA, code))
    if with_ollama and (gated != 1 or plain):
        return ['ChatView must get `current: full.onChat && root.expanded && root.chatSiteId !== "ollama"`']
    if not with_ollama and plain + gated != 1:
        return ["ChatView must get `current: full.onChat && root.expanded`"]
    return []


@pytest.mark.parametrize(("with_ollama", "old", "new"), [
    (False, "current: full.onChat && root.expanded", "current: full.onChat"),
    (True, 'current: full.onChat && root.expanded && root.chatSiteId !== "ollama"',
     "current: full.onChat && root.expanded"),
    (True, 'current: full.onChat && root.expanded && root.chatSiteId !== "ollama"',
     'current: full.onChat && root.expanded && root.chatSiteId === "ollama"'),
])
def test_proof_chat_view_current_rule_catches(with_ollama, old, new):
    assert _chat_view_current_problems(_mutated(FULL_REPRESENTATION, old, new), with_ollama)


# --- helper commands: built only in ChatStorage.js -------------------------------------

HELPER_FLAGS = ("--vault", "--web-data", "--store", "--applet", "--generation", "--keep")


def _helper_flag_offenders(sources):
    return [
        f"{name}:{line} {flag}"
        for name, code in sources.items() if not name.endswith("ChatStorage.js")
        for flag in HELPER_FLAGS
        for line in _hits(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", code)
    ]


def test_helper_flags_appear_only_in_chat_storage_js():
    offenders = _helper_flag_offenders(_all_code())
    assert not offenders, f"helper commands must be built by ChatStorage.js only: {offenders}"


def _chat_storage_problems(raw):
    code = _strip_comments(raw)
    problems = []
    if not re.match(r"\s*\.pragma\s+library\b", code):
        problems.append("must start with .pragma library")
    if _hits(r"(?m)^\s*(?:\.import\b|import\b)", code) + _hits(r"\bQt\.include\s*\(", code):
        problems.append("must not import anything")
    # The only store is the encrypted one; no plaintext profile folder exists.
    if _hits(r"""["']folder["']""", code):
        problems.append('must not name the old "folder" store')
    if re.findall(r"--store\s+(\w+)", code) != ["encrypted"]:
        problems.append("--store must be the literal `--store encrypted`, once")
    ops = re.search(r"VAULT_OPERATIONS\s*=\s*\[([^\]]*)\]", code)
    allowed = '"status", "create", "unlock", "lock", "change-passphrase", "destroy"'
    if not ops or re.sub(r"\s+", " ", ops.group(1)).strip() != allowed:
        problems.append(f"VAULT_OPERATIONS must be exactly [{allowed}]")
    # Every argv value is validated: no raw concatenation of op or numbers
    # other than through the checked branches.
    if _hits(r"\beval\s*\(|\bFunction\s*\(", code):
        problems.append("no eval")
    return problems


def test_chat_storage_js_is_a_pure_strict_command_builder():
    problems = _chat_storage_problems(CHAT_STORAGE_JS.read_text(encoding="utf-8"))
    assert not problems, f"{_rel(CHAT_STORAGE_JS)}: {problems}"


def _web_data_store_offenders(sources):
    return [
        f"{name}:{_line_of(code, match.start())}"
        for name, code in sources.items()
        for match in re.finditer(r"(?<!function )\bwebDataCommand\s*\(\s*([^,]*),\s*([^,]*),", code)
        if match.group(2).strip() != '"encrypted"'
    ]


def test_web_data_commands_always_use_the_encrypted_store():
    offenders = _web_data_store_offenders(_all_code())
    assert not offenders, f'webDataCommand must be called with the literal store "encrypted": {offenders}'


def _helper_stderr_offenders(sources):
    offenders = []
    for name, code in sources.items():
        for start, body in _blocks(code, r"\bPlasma5Support\.DataSource\s*\{"):
            if re.search(r"\bid\s*:\s*(?:storageSource|vaultSource)\b", body) and re.search(r"stderr", body):
                offenders.append(f"{name}:{_line_of(code, start)}")
    return offenders


def test_storage_helper_replies_never_read_stderr():
    offenders = _helper_stderr_offenders(_all_code())
    assert not offenders, f"storage helper DataSources must only read stdout's known words: {offenders}"


# --- secrets and dangerous gocryptfs options never appear in plasmoid/ ------------------

# Anywhere, strings included: the plasmoid never handles key material or
# gives gocryptfs options; purge exists only for install.sh.
FORBIDDEN_WORDS = {
    "purge": r"(?i)purge",
    "extpass": r"(?i)extpass",
    "passfile": r"(?i)passfile",
    "masterkey": r"(?i)masterkey",
    "allow_other": r"(?i)allow_other",
    "allow_root": r"(?i)allow_root",
    "plaintextnames": r"(?i)plaintextnames",
    "echoMode": r"\bechoMode\b",
    "PasswordField": r"\bPasswordField\b",
    "TextInput.Password": r"\bTextInput\s*\.\s*Password\b",
}


def _all_text():
    return {
        _rel(path): (_read_code(path) if path.suffix in {".qml", ".js"} else path.read_text(encoding="utf-8"))
        for path in sorted(PLASMOID.rglob("*")) if path.is_file() and path.suffix in {".qml", ".js", ".json", ".xml", ".desktop"}
    }


def _forbidden_word_offenders(sources):
    return [
        f"{name}:{line} {word}"
        for name, code in sources.items()
        for word, pattern in FORBIDDEN_WORDS.items()
        for line in _hits(pattern, code)
    ]


def test_plasmoid_never_names_key_material_or_unsafe_options():
    offenders = _forbidden_word_offenders(_all_text())
    assert not offenders, f"forbidden in plasmoid/: {offenders}"


def _secret_identifier_offenders(sources):
    # Code with strings blanked: a passphrase never has a property, variable
    # or field. (User-facing text like "Change passphrase…" is a string.)
    return [
        f"{name}:{line}"
        for name, code in sources.items() if name.endswith((".qml", ".js"))
        for line in _hits(r"(?i)pass(?:phrase|word)", _strip_comments(code, blank_strings=True))
    ]


def test_no_code_identifier_holds_a_passphrase():
    offenders = _secret_identifier_offenders(_all_text())
    assert not offenders, f"no identifier may name a passphrase or password: {offenders}"


def _shown_path_offenders(sources):
    return [
        f"{name}:{line}"
        for name, code in sources.items() if name.endswith(".qml")
        for line in _hits(r"\b(?:text|placeholderText|ToolTip\.text)\s*:[^\n]*\b(?:storagePath|chatProfilePath|"
                          r"profileName|chatProfileName|StandardPaths)\b", code)
    ]


def test_profile_path_is_never_shown():
    offenders = _shown_path_offenders(_all_code())
    assert not offenders, f"the profile path or name must never be shown: {offenders}"


# --- proof: every rule above fails on a violating copy of the real file ----------------


def _mutated(path, old, new):
    raw = path.read_text(encoding="utf-8")
    assert old in raw, f"proof fixture out of date: {old!r} not in {_rel(path)}"
    return _strip_comments(raw.replace(old, new, 1))


PROFILE_MUTATIONS = {
    "offTheRecord first": (
        "        persistentStoragePath: chatWeb.staySignedIn",
        "        offTheRecord: !chatWeb.staySignedIn\n        persistentStoragePath: chatWeb.staySignedIn",
    ),
    "storageName before paths": (
        "        persistentStoragePath: chatWeb.staySignedIn ? chatWeb.storagePath : \"\"\n",
        "        storageName: \"x\"\n        persistentStoragePath: chatWeb.staySignedIn ? chatWeb.storagePath : \"\"\n",
    ),
    "always persistent": ("offTheRecord: !chatWeb.staySignedIn", "offTheRecord: false"),
    "path without gate": ("cachePath: chatWeb.staySignedIn ? chatWeb.storagePath : \"\"",
                          "cachePath: chatWeb.storagePath"),
    "disk cache": ("WebEngineProfile.MemoryHttpCache", "WebEngineProfile.DiskHttpCache"),
    "forced cookies": ("WebEngineProfile.AllowPersistentCookies", "WebEngineProfile.ForcePersistentCookies"),
    "second profile": ("    WebEngineProfile {\n", "    WebEngineProfile { id: other }\n    WebEngineProfile {\n"),
}


@pytest.mark.parametrize("name", sorted(PROFILE_MUTATIONS))
def test_proof_profile_rule_catches(name):
    code = _mutated(CHAT_WEB_VIEW, *PROFILE_MUTATIONS[name])
    assert _profile_problems(code) or _storage_offenders({"ChatWebView.qml": code})


def test_proof_live_profile_switch_is_caught():
    code = _mutated(CHAT_WEB_VIEW, "    function goBack() {", "    function flip() { chatProfile.offTheRecord = false }\n    function goBack() {")
    assert _storage_offenders({"ChatWebView.qml": code})


def test_proof_profile_names_outside_chat_web_view_are_caught():
    code = _mutated(CHAT_VIEW, "    spacing: 0\n", "    spacing: 0\n    property string storageName: \"\"\n")
    assert _storage_offenders({"ChatView.qml": code})


@pytest.mark.parametrize("old,new", [
    ("    property bool staySignedIn: false", "    property bool staySignedIn: true"),
    ("    property string storagePath: \"\"", "    property string storagePath: \"/tmp/x\""),
    ("    function goBack() {", "    function goBack() {\n        chatWeb.staySignedIn = true"),
])
def test_proof_web_view_inputs_rule_catches(old, new):
    assert _web_view_inputs_problems(_mutated(CHAT_WEB_VIEW, old, new))


@pytest.mark.parametrize("old,new", [
    ("staySignedIn: chatView.persistentReady,", "staySignedIn: chatView.storageReady,"),
    ("chatView.encrypted && chatView.storageReady", "chatView.storageReady"),
    ("&& chatView.storagePath !== \"\" && chatView.profileName !== \"\"", ""),
    ("            active: false\n", "            active: chatView.started\n            source: \"ChatWebView.qml\"\n"),
    ("    function start() {", "    function hack() { webLoader.setSource(\"ChatWebView.qml\", {}) }\n    function start() {"),
])
def test_proof_chat_view_gate_rule_catches(old, new):
    assert _chat_view_gate_problems(_mutated(CHAT_VIEW, old, new))


def test_proof_stay_signed_in_elsewhere_is_caught():
    code = _mutated(FULL_REPRESENTATION, "            storageReady: root.chatStorageReady",
                    "            storageReady: root.chatStorageReady\n            Component.onCompleted: web.staySignedIn = true")
    assert _stay_signed_in_elsewhere({"FullRepresentation.qml": code})


@pytest.mark.parametrize("old,new", [
    ("&& root.chatVaultState === \"unlocked\"\n", "\n"),
    ("                root.chatPreparedGeneration = root.chatGeneration\n",
     "                root.chatPreparedGeneration = root.chatGeneration\n"
     "            root.chatPreparedGeneration = root.chatGeneration\n"),
    ("if (reply.ok && root.chatOpGeneration", "if (root.chatOpGeneration"),
])
def test_proof_main_ready_rule_catches(old, new):
    assert _main_ready_problems(_mutated(MAIN_QML, old, new), _read_code(FULL_REPRESENTATION))


def test_proof_full_representation_ready_binding_is_caught():
    code = _mutated(FULL_REPRESENTATION, "storageReady: root.chatStorageReady", "storageReady: true")
    assert _main_ready_problems(_read_code(MAIN_QML), code)


def test_proof_helper_flag_outside_chat_storage_is_caught():
    code = _mutated(MAIN_QML, "    function chatNext() {",
                    "    function x() { return \"python3 -m hearthside --vault status\" }\n    function chatNext() {")
    assert _helper_flag_offenders({"main.qml": code})


@pytest.mark.parametrize("old,new", [
    (".pragma library", ""),
    ("var MODES", "import QtQuick as Q\nvar MODES"),
    ("store !== \"encrypted\"", "store !== \"encrypted\" && store !== \"folder\""),
    ('"change-passphrase", "destroy"]', '"change-passphrase", "destroy", "purge"]'),
])
def test_proof_chat_storage_rule_catches(old, new):
    raw = CHAT_STORAGE_JS.read_text(encoding="utf-8")
    assert old in raw
    assert _chat_storage_problems(raw.replace(old, new, 1))


def test_proof_plaintext_store_call_is_caught():
    code = _mutated(MAIN_QML, 'ChatStorage.webDataCommand("prepare", "encrypted",',
                    'ChatStorage.webDataCommand("prepare", root.chatStorageMode,')
    assert _web_data_store_offenders({"main.qml": code})


def test_proof_stderr_in_storage_source_is_caught():
    code = _mutated(MAIN_QML, "            storageSource.disconnectSource(source)\n",
                    "            storageSource.disconnectSource(source)\n            var e = data[\"stderr\"]\n")
    assert _helper_stderr_offenders({"main.qml": code})


@pytest.mark.parametrize("snippet", [
    "var a = \"--web-data purge\"",
    "var a = \"-passfile\"",
    "var a = \"-masterkey=1\"",
    "var a = \"-allow_other\"",
    "var a = \"-plaintextnames\"",
    "var a = \"-extpass=kdialog\"",
    "echoMode: TextInput.Password",
    "Kirigami.PasswordField {}",
])
def test_proof_forbidden_word_is_caught(snippet):
    assert _forbidden_word_offenders({"x.qml": snippet})


@pytest.mark.parametrize("snippet", ["property string passphrase: \"\"", "var userPassword = 1"])
def test_proof_secret_identifier_is_caught(snippet):
    assert _secret_identifier_offenders({"x.qml": snippet})


def test_proof_shown_path_is_caught():
    assert _shown_path_offenders({"x.qml": "    text: chatView.storagePath\n"})


# --- handlers and settings ------------------------------------------------------


def _handler_bodies(code, signal):
    return list(_blocks(code, rf"\b{signal}\s*:\s*(?:function\s*\([^)]*\)\s*|\([^)]*\)\s*=>\s*|\w+\s*=>\s*)?\{{"))


def test_console_messages_are_swallowed_by_an_empty_handler():
    code = _read_code(CHAT_WEB_VIEW)
    views = _hits(r"\bWebEngineView\s*\{", code)
    handlers = _handler_bodies(code, "onJavaScriptConsoleMessage")
    assert handlers, f"{_rel(CHAT_WEB_VIEW)} must define an onJavaScriptConsoleMessage handler"
    assert len(handlers) >= len(views), (
        f"{_rel(CHAT_WEB_VIEW)}: {len(views)} WebEngineView declarations but only "
        f"{len(handlers)} onJavaScriptConsoleMessage handlers; page logs would reach the journal"
    )
    non_empty = [_line_of(code, start) for start, body in handlers if body[1:-1].strip()]
    assert not non_empty, (
        f"{_rel(CHAT_WEB_VIEW)}: onJavaScriptConsoleMessage handlers must be empty; lines {non_empty}"
    )


def test_permission_requests_are_always_denied():
    code = _read_code(CHAT_WEB_VIEW)
    handlers = _handler_bodies(code, "onPermissionRequested")
    assert handlers, f"{_rel(CHAT_WEB_VIEW)} must define an onPermissionRequested handler"
    without_deny = [_line_of(code, start) for start, body in handlers if not re.search(r"\.deny\s*\(", body)]
    assert not without_deny, (
        f"{_rel(CHAT_WEB_VIEW)}: onPermissionRequested must call permission.deny(); lines {without_deny}"
    )
    grants = _hits(r"\.grant\s*\(", code) + _hits(r"\bgrantFeaturePermission\s*\([^)]*\btrue\b", code)
    assert not grants, f"{_rel(CHAT_WEB_VIEW)} must never grant a site permission; lines {grants}"


@pytest.mark.parametrize(
    "setting",
    [
        "javascriptCanAccessClipboard",
        "javascriptCanPaste",
        "screenCaptureEnabled",
        "localContentCanAccessFileUrls",
        "allowRunningInsecureContent",
    ],
)
def test_privacy_sensitive_settings_are_disabled(setting):
    code = _read_code(CHAT_WEB_VIEW)
    assert _hits(rf"\b{setting}\s*:\s*false\b", code), f"{_rel(CHAT_WEB_VIEW)} must set {setting}: false"
    enabled = _hits(rf"\b{setting}\s*:(?!\s*false\b)", code)
    assert not enabled, f"{_rel(CHAT_WEB_VIEW)} must not set {setting} to anything but false; lines {enabled}"


# --- no page access, no env, no logging -------------------------------------------


FORBIDDEN_ANYWHERE = {
    "runJavaScript": r"\brunJavaScript\b",
    "userScripts": r"\buserScripts\b",
    "WebEngineScript": r"\bWebEngineScript\b",
    "webChannel": r"\bwebChannel\b",
    "QtWebChannel": r"\bQtWebChannel\b",
    "QTWEBENGINE": r"QTWEBENGINE",
}


@pytest.mark.parametrize("name", sorted(FORBIDDEN_ANYWHERE))
def test_plasmoid_never_reads_or_injects_into_pages(name):
    pattern = FORBIDDEN_ANYWHERE[name]
    offenders = [
        f"{_rel(path)}:{line}"
        for path in _code_files()
        for line in _hits(pattern, _read_code(path))
    ] + [
        f"{_rel(path)}:{line}"
        for path in _text_files()
        for line in _hits(pattern, path.read_text(encoding="utf-8"))
    ]
    assert not offenders, f"{name} is forbidden anywhere in plasmoid/; found at {offenders}"


def _log_offenders(sources):
    return [
        f"{name}:{line}"
        for name, code in sources.items()
        for line in _hits(r"\bconsole\b", code) + _hits(r"(?<![\w.])print\s*\(", code)
    ]


def test_plasmoid_never_logs():
    offenders = _log_offenders(_all_code())
    assert not offenders, f"plasmoid code must not log (console.* or print()): {offenders}"


def test_proof_logging_is_caught():
    code = _mutated(MAIN_QML, "    function chatNext() {", "    function chatNext() {\n        console.warn(1)")
    assert _log_offenders({"main.qml": code})


# --- user agent: Firefox only on Google sign-in, never set inside a request ---------
#
# Setting the profile's user agent from inside a navigation request aborts Qt
# WebEngine (experiment 2026-11-01), so it is written only by applyUserAgent,
# which navigation handling may call only through Qt.callLater, plus the one
# initial assignment when the item is created.

USER_AGENT_WRITE = r"\b(?:httpUserAgent|clientHints\s*\.\s*\w+)\s*=(?!=)"


def _block_spans(code, opener):
    spans = []
    for start, body in _blocks(code, opener):
        offset = code.index(body, start)
        spans.append((offset, offset + len(body)))
    return spans


def _without_deferred(body):
    """``body`` with the contents of every ``Qt.callLater(function ...)`` blanked."""
    blanked = body
    for start, inner in _blocks(body, r"\bQt\.callLater\s*\(\s*function\s*\([^)]*\)\s*\{"):
        offset = body.index(inner, start)
        blanked = blanked[:offset] + " " * len(inner) + blanked[offset + len(inner):]
    return blanked


def _user_agent_problems(code):
    problems = []
    allowed = _block_spans(code, r"\bfunction\s+applyUserAgent\s*\([^)]*\)\s*\{")
    if len(allowed) != 1:
        return [f"exactly one applyUserAgent function expected, found {len(allowed)}"]
    # The one initial assignment, when the item is created.
    initial = [
        match.start(1) for match in re.finditer(
            r"(?m)^\s*chatProfile\.(httpUserAgent)\s*=\s*chatWeb\.baseUserAgent\s*$", code)
    ]
    for match in re.finditer(USER_AGENT_WRITE, code):
        inside = any(lo <= match.start() < hi for lo, hi in allowed)
        if not inside and match.start() not in initial:
            problems.append(f"user agent or client hints written outside applyUserAgent (line {_line_of(code, match.start())})")
    if len(initial) != 1:
        problems.append(f"exactly one initial `chatProfile.httpUserAgent = chatWeb.baseUserAgent` expected, found {len(initial)}")
    synchronous = [
        body for opener in (r"\bfunction\s+checkUserAgent\s*\([^)]*\)\s*\{",)
        for _, body in _blocks(code, opener)
    ] + [body for _, body in _handler_bodies(code, "onNavigationRequested")]
    if not synchronous:
        problems.append("navigation handling (onNavigationRequested / checkUserAgent) not found")
    for body in synchronous:
        rest = _without_deferred(body)
        if re.search(r"\bapplyUserAgent\s*\(|" + USER_AGENT_WRITE, rest):
            problems.append("navigation handling may switch the user agent only through Qt.callLater")
    return problems


def test_user_agent_is_switched_only_outside_navigation_requests():
    problems = _user_agent_problems(_read_code(CHAT_WEB_VIEW))
    assert not problems, f"{_rel(CHAT_WEB_VIEW)}: {problems}"


USER_AGENT_MUTATIONS = {
    "sync switch in request": (
        "                request.reject()\n                page.userAgentRetry = url\n",
        "                chatWeb.applyUserAgent(ChatSites.GOOGLE_SIGNIN_UA)\n"
        "                request.reject()\n                page.userAgentRetry = url\n",
    ),
    "direct write elsewhere": (
        "    function syncUserAgent() {\n",
        "    function syncUserAgent() {\n        chatProfile.httpUserAgent = \"x\"\n",
    ),
    "hints written elsewhere": (
        "    function syncUserAgent() {\n",
        "    function syncUserAgent() {\n        chatProfile.clientHints.isAllClientHintsEnabled = true\n",
    ),
}


@pytest.mark.parametrize("name", sorted(USER_AGENT_MUTATIONS))
def test_proof_user_agent_rule_catches(name):
    assert _user_agent_problems(_mutated(CHAT_WEB_VIEW, *USER_AGENT_MUTATIONS[name]))


def test_firefox_user_agent_is_declared_only_in_chat_sites_js():
    offenders = [
        f"{_rel(path)}:{line}"
        for path in _code_files() if path != CHAT_SITES_JS
        for line in _hits(r"Firefox/|Gecko/\d", _read_code(path))
    ]
    assert not offenders, f"the Google sign-in user agent belongs in ChatSites.js only: {offenders}"
    assert len(_hits(r"Gecko/\d+ Firefox/", _read_code(CHAT_SITES_JS))) == 1


# --- persisted configuration ------------------------------------------------------


def _chat_config_keys():
    """The chat key set: chatOllamaUrl joins once main.xml has it or the Ollama view exists."""
    keys = dict(CHAT_CONFIG_KEYS)
    if OLLAMA_CHAT_VIEW.is_file() or set(OLLAMA_CONFIG_KEYS) & set(_main_xml_entries()):
        keys.update(OLLAMA_CONFIG_KEYS)
    return keys


def test_main_xml_adds_only_the_chat_keys():
    entries = _main_xml_entries()
    expected = _chat_config_keys()
    chat_keys = {name for name in entries if name.lower().startswith("chat")}
    assert chat_keys == set(expected), (
        f"{_rel(MAIN_XML)} chat entries must be exactly {sorted(expected)}, got {sorted(chat_keys)}"
    )
    unexpected = set(entries) - set(expected) - PRE_CHAT_CONFIG_KEYS
    assert not unexpected, f"{_rel(MAIN_XML)} has new persisted keys besides the chat ones: {sorted(unexpected)}"
    for key, (kind, default) in sorted(expected.items()):
        assert entries[key]["group"] == "General", f"{_rel(MAIN_XML)}: {key} must be in group General"
        assert entries[key]["type"] == kind, f"{_rel(MAIN_XML)}: {key} must have type {kind}"
        if default is not None:
            assert entries[key]["default"] == default, (
                f"{_rel(MAIN_XML)}: {key} default must be exactly {default!r}, got {entries[key]['default']!r}"
            )


@pytest.mark.parametrize("filename", CHAT_CONFIG_READ_ONLY_FILES)
def test_chat_files_never_write_the_plasmoid_config(filename):
    path = UI / filename
    _require_phased(path)
    code = _read_code(path)
    config = r"\b[Pp]lasmoid\s*\.\s*configuration"
    member = r"(?:\s*\.\s*\w+|\s*\[[^\]]*\])"
    lines = (
        # Plain or compound assignment: x = v, x += v, x ??= v (not ==).
        _hits(rf"{config}{member}+\s*(?:[-+*/%&|^]|\*\*|<<|>>>?|&&|\|\||\?\?)?=(?!=)", code)
        # Increment and decrement on either side.
        + _hits(rf"{config}{member}+\s*(?:\+\+|--)", code)
        + _hits(rf"(?:\+\+|--)\s*{config}", code)
        # The config object itself handed around, e.g. `var c = Plasmoid.configuration`.
        + _hits(rf"{config}(?!\s*[.\[])", code)
    )
    assert not lines, f"{_rel(path)} must never write Plasmoid.configuration; lines {sorted(set(lines))}"


def _main_config_write_offenders(code):
    """main.qml may write chatProfileGeneration and no other chat key."""
    return [
        f"{_line_of(code, match.start())} {match.group(1)}"
        for match in re.finditer(r"\bPlasmoid\s*\.\s*configuration\s*\.\s*(chat\w*)\s*(?:[-+*/%&|^]|\?\?)?=(?!=)", code)
        if match.group(1) != "chatProfileGeneration"
    ] + [
        str(line) for line in _hits(r"\bPlasmoid\s*\.\s*configuration\s*\[", code)
    ]


def test_main_writes_only_the_profile_generation_chat_key():
    offenders = _main_config_write_offenders(_read_code(MAIN_QML))
    assert not offenders, f"{_rel(MAIN_QML)} may only write chatProfileGeneration among chat keys: {offenders}"


def test_proof_main_chat_config_write_is_caught():
    code = _mutated(MAIN_QML, "    function chatNext() {",
                    "    function x() { Plasmoid.configuration.chatSignInStorage = \"encrypted\" }\n    function chatNext() {")
    assert _main_config_write_offenders(code)


@pytest.mark.parametrize("page", CONFIG_PAGES, ids=lambda path: path.name)
def test_config_pages_declare_every_chat_key_and_never_write_config(page):
    code = _read_code(page)
    expected = _chat_config_keys()
    for key, (kind, default) in expected.items():
        qml_type = {"String": "string", "Int": "int", "Bool": "bool"}[kind]
        for name in (f"cfg_{key}", f"cfg_{key}Default"):
            declared = re.findall(rf"(?m)^\s*property\s+(\w+)\s+{name}\s*:\s*(.+)$", code)
            assert len(declared) == 1 and declared[0][0] == qml_type, (
                f"{_rel(page)} must declare `property {qml_type} {name}` once, got {declared}"
            )
    literals = {"chatSignInStorage": '"memory"', "chatProfileGeneration": "0"}
    if "chatOllamaUrl" in expected:
        literals["chatOllamaUrl"] = f'"{OLLAMA_CONFIG_KEYS["chatOllamaUrl"][1]}"'
    for key, literal in literals.items():
        for name in (f"cfg_{key}", f"cfg_{key}Default"):
            value = re.findall(rf"(?m)^\s*property\s+\w+\s+{name}\s*:\s*(.+?)\s*$", code)
            assert value == [literal], f"{_rel(page)}: {name} must default to {literal}, got {value}"
    writes = _hits(r"\bPlasmoid\s*\.\s*configuration\s*(?:\.\s*\w+|\[[^\]]*\])\s*=(?!=)", code)
    assert not writes, f"{_rel(page)} must write cfg_ properties, never Plasmoid.configuration; lines {writes}"
    gen_writes = [
        line for line in _hits(r"\bcfg_chatProfileGeneration\s*=(?!=)", code)
    ]
    assert len(gen_writes) <= 1, f"{_rel(page)}: cfg_chatProfileGeneration may only be synced from the config"


def test_chat_sites_js_declares_the_expected_sites_in_order():
    site_ids = _chat_site_ids()
    assert site_ids == EXPECTED_SITE_IDS, (
        f"{_rel(CHAT_SITES_JS)} site ids must be {EXPECTED_SITE_IDS} in that order, got {site_ids}"
    )
    assert list(_chat_sites()) == EXPECTED_SITE_IDS, (
        f"{_rel(CHAT_SITES_JS)}: every top-level site object must have a literal id"
    )


def test_chat_sites_default_is_the_default_on_sites_in_order():
    entries = _main_xml_entries()
    assert "chatSites" in entries, f"{_rel(MAIN_XML)} has no chatSites entry"
    raw_default = entries["chatSites"]["default"]
    try:
        configured = json.loads(raw_default or "")
    except json.JSONDecodeError as error:
        raise AssertionError(f"{_rel(MAIN_XML)}: chatSites default is not JSON: {error}") from None
    assert configured == EXPECTED_DEFAULT_SITE_IDS, (
        f"{_rel(MAIN_XML)} chatSites default {configured} must be {EXPECTED_DEFAULT_SITE_IDS} (no {LOCAL_SITE_ID})"
    )
    default_on = [
        site_id for site_id, site in _chat_sites().items()
        if not re.search(r"""[{,]\s*["']?default_on["']?\s*:\s*false\b""", site)
    ]
    assert default_on == EXPECTED_DEFAULT_SITE_IDS, (
        f"{_rel(CHAT_SITES_JS)}: sites without default_on: false must be {EXPECTED_DEFAULT_SITE_IDS}, got {default_on}"
    )


def test_local_site_is_off_by_default_and_the_only_local_site():
    sites = _chat_sites()
    assert LOCAL_SITE_ID in sites, f"{_rel(CHAT_SITES_JS)} has no {LOCAL_SITE_ID} site"
    local = sites[LOCAL_SITE_ID]
    assert re.search(r"""[{,]\s*["']?default_on["']?\s*:\s*false\s*[,}\n]""", local), (
        f"{_rel(CHAT_SITES_JS)}: the {LOCAL_SITE_ID} site must say literally `default_on: false`"
    )
    assert re.search(r"""[{,]\s*["']?local["']?\s*:\s*true\s*[,}\n]""", local), (
        f"{_rel(CHAT_SITES_JS)}: the {LOCAL_SITE_ID} site must say literally `local: true`"
    )
    others = {
        site_id: _key_hits(site, "local", "false") + _key_hits(site, "default_on", "true")
        for site_id, site in sites.items() if site_id != LOCAL_SITE_ID
    }
    offenders = {site_id: hits for site_id, hits in others.items() if hits}
    assert not offenders, (
        f"{_rel(CHAT_SITES_JS)}: only {LOCAL_SITE_ID} may set `local` (other than false) "
        f"or `default_on` (other than true): {offenders}"
    )


_LOCAL_HTTP_URL = re.compile(r"http://(?:localhost|127\.0\.0\.1)(?::\d{1,5})?(?:/|$)")


def test_site_urls_are_https_except_the_local_loopback_site():
    wrong = {}
    for site_id, site in _chat_sites().items():
        url = _site_key(site, "url")
        if url is None:
            wrong[site_id] = "no literal url"
        elif site_id == LOCAL_SITE_ID:
            if not _LOCAL_HTTP_URL.match(url):
                wrong[site_id] = url
        elif not url.startswith("https://"):
            wrong[site_id] = url
    assert not wrong, (
        f"{_rel(CHAT_SITES_JS)}: site urls must be https:// (only {LOCAL_SITE_ID} may use "
        f"http://localhost or http://127.0.0.1): {wrong}"
    )


def test_chat_default_site_default_is_a_known_site():
    entries = _main_xml_entries()
    assert "chatDefaultSite" in entries, f"{_rel(MAIN_XML)} has no chatDefaultSite entry"
    default = (entries["chatDefaultSite"]["default"] or "").strip()
    assert default == "claude", f"{_rel(MAIN_XML)}: chatDefaultSite default must be claude, got {default!r}"
    assert default in _chat_site_ids(), f"{_rel(MAIN_XML)}: chatDefaultSite {default!r} is not in ChatSites.js"


# --- built-in Ollama chat (plan "Policy rules" P1-P11) -----------------------------
#
# OllamaChat.js (T1) and OllamaChatView.qml (T4) arrive in later phases. Each
# rule about them skips while its file is missing and enforces once it exists.
# Rule checkers take source text; the proofs feed them a violating copy of the
# real file when it exists, else of the small compliant sample below, so the
# proofs run in every phase.

# A minimal view that follows every rule. Used only when the real view is
# missing, and kept here (not in plasmoid/) so it never counts as plasmoid code.
SAMPLE_OLLAMA_VIEW = """\
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import "OllamaChat.js" as OllamaChat

Item {
    id: ollamaView
    property var createRequest: function () { return new XMLHttpRequest() }
    property var runOwnerCheck: function (command) { ownerSource.connectSource(command) }

    function loadTags(address) {
        var xhr = ollamaView.createRequest()
        xhr.open("GET", OllamaChat.endpoint(address, "tags"))
        xhr.send()
    }
    function sendChat(address, body) {
        var xhr = ollamaView.createRequest()
        xhr.open("POST", OllamaChat.endpoint(address, "chat"))
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body)
        confirm.open()
    }
    Plasma5Support.DataSource {
        id: ownerSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            ownerSource.disconnectSource(source)
            ollamaView.ownerDone(OllamaChat.parseOwnerReply(data["exit code"], data["stdout"]))
        }
    }
    QQC2.Label {
        text: i18n("Ollama isn't running.")
        textFormat: Text.PlainText
    }
    Kirigami.Heading { text: i18n("Ollama"); textFormat: Text.PlainText }
    TextEdit {
        readOnly: true
        textFormat: TextEdit.PlainText
        text: "reply"
    }
    QQC2.TextArea {
        id: input
        textFormat: TextEdit.PlainText
        Kirigami.SpellCheck.enabled: false
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
    }
}
"""
SAMPLE_OLLAMA_JS = """\
.pragma library

var DEFAULT_ADDRESS = "http://127.0.0.1:11434"

function ownerCommand(port, run, applet) {
    return "env HEARTHSIDE_RUN=" + run + " HEARTHSIDE_APPLET=" + applet
        + " python3 -m hearthside --port-owner " + port
}
"""


def _ollama_source(path, sample):
    """The real file when it exists, else the compliant sample (for proofs)."""
    return path.read_text(encoding="utf-8") if path.is_file() else sample


def _mutated_source(path, sample, old, new):
    raw = _ollama_source(path, sample)
    assert old in raw, f"proof fixture out of date: {old!r} not in {path.name}"
    return _strip_comments(raw.replace(old, new, 1))


def _inserted_view(snippet):
    """The view (real or sample) with ``snippet`` added as the root item's first child."""
    raw = _ollama_source(OLLAMA_CHAT_VIEW, SAMPLE_OLLAMA_VIEW)
    blanked = _strip_comments(raw, blank_strings=True)
    match = re.search(r"(?m)^[A-Za-z_][\w.]*\s*\{", blanked)
    assert match, "the view has no root item"
    end = match.end()
    return _strip_comments(raw[:end] + "\n" + snippet + "\n" + raw[end:])


def _inserted_js(snippet):
    raw = _ollama_source(OLLAMA_CHAT_JS, SAMPLE_OLLAMA_JS)
    head, sep, tail = raw.partition(".pragma library\n")
    assert sep, "OllamaChat.js must start with .pragma library"
    return head + sep + snippet + "\n" + tail


def test_ollama_samples_follow_every_rule():
    # The proofs below are only meaningful if the unmutated inputs pass.
    view = _strip_comments(SAMPLE_OLLAMA_VIEW)
    assert not _ollama_js_problems(SAMPLE_OLLAMA_JS)
    assert not _ollama_request_problems(view)
    assert not _plain_text_problems(view)
    assert not _input_privacy_problems(view)
    assert not _port_owner_flag_problems({"OllamaChatView.qml": view,
                                          "OllamaChat.js": _strip_comments(SAMPLE_OLLAMA_JS)})
    assert not _seam_problems({"OllamaChatView.qml": view}, view_present=True)
    assert not _xhr_offenders({"OllamaChatView.qml": view})
    assert not _ollama_storage_offenders({"OllamaChatView.qml": view,
                                          "OllamaChat.js": _strip_comments(SAMPLE_OLLAMA_JS)})


# P1 OllamaChat.js is a pure library: no imports, no requests, no Qt, no logs, no storage.

OLLAMA_JS_FORBIDDEN = {
    "XMLHttpRequest": r"\bXMLHttpRequest\b",
    "Qt.": r"\bQt\s*\.",
    "console": r"\bconsole\b",
    "LocalStorage": r"\bLocalStorage\b",
    "openDatabaseSync": r"\bopenDatabaseSync\b",
    "eval": r"\beval\s*\(|\bFunction\s*\(",
}


def _ollama_js_problems(raw):
    code = _strip_comments(raw)
    problems = []
    if not re.match(r"\s*\.pragma\s+library\b", code):
        problems.append("must start with .pragma library")
    imports = _hits(r"(?m)^\s*(?:\.import\b|import\b)", code) + _hits(r"\bQt\.include\s*\(", code)
    if imports:
        problems.append(f"must not import anything (lines {imports})")
    for name, pattern in OLLAMA_JS_FORBIDDEN.items():
        lines = _hits(pattern, code)
        if lines:
            problems.append(f"must not use {name} (lines {lines})")
    return problems


def test_ollama_chat_js_is_a_pure_library():
    _require_phased(OLLAMA_CHAT_JS)
    problems = _ollama_js_problems(OLLAMA_CHAT_JS.read_text(encoding="utf-8"))
    assert not problems, f"{_rel(OLLAMA_CHAT_JS)}: {problems}"


@pytest.mark.parametrize("snippet", [
    "import QtQuick 2.15",
    ".import \"ChatSites.js\" as ChatSites",
    "Qt.include(\"x.js\")",
    "function get(u) { var x = new XMLHttpRequest(); return x }",
    "function open(u) { Qt.openUrlExternally(u) }",
    "function log(t) { console.log(t) }",
    "var db = LocalStorage.openDatabaseSync(\"x\", \"1\", \"x\", 1)",
    "var f = eval(\"1\")",
])
def test_proof_ollama_chat_js_rule_catches(snippet):
    assert _ollama_js_problems(_inserted_js(snippet))


def test_proof_ollama_chat_js_needs_pragma():
    assert _ollama_js_problems(_ollama_source(OLLAMA_CHAT_JS, SAMPLE_OLLAMA_JS).replace(".pragma library", "", 1))


# P2 XMLHttpRequest only in OllamaChatView.qml, and there only as the createRequest default.

CREATE_REQUEST_DECLARATION = (
    r"(?m)^[ \t]*property\s+var\s+createRequest\s*:\s*function\s*\(\s*\)\s*\{\s*"
    r"return\s+new\s+XMLHttpRequest\s*\(\s*\)\s*;?\s*\}\s*$"
)


def _xhr_offenders(sources):
    offenders = []
    for name, code in sources.items():
        lines = _hits(r"\bXMLHttpRequest\b", code)
        if not name.endswith("OllamaChatView.qml"):
            offenders += [f"{name}:{line}" for line in lines]
        elif lines != _hits(CREATE_REQUEST_DECLARATION, code) or len(lines) > 1:
            offenders.append(f"{name}: XMLHttpRequest only once, as "
                             "`property var createRequest: function () { return new XMLHttpRequest() }`")
    return offenders


def test_xml_http_request_only_in_the_ollama_view():
    offenders = _xhr_offenders(_all_code())
    assert not offenders, f"XMLHttpRequest belongs to OllamaChatView.qml only: {offenders}"


def test_proof_xml_http_request_elsewhere_is_caught():
    code = _mutated(MAIN_QML, "    function chatNext() {",
                    "    function x() { return new XMLHttpRequest() }\n    function chatNext() {")
    assert _xhr_offenders({"main.qml": code})


def test_proof_second_xml_http_request_in_view_is_caught():
    view = _inserted_view("    function raw() { return new XMLHttpRequest() }")
    assert _xhr_offenders({"OllamaChatView.qml": view})


# P3 Requests go only to OllamaChat.endpoint() with GET or POST and one JSON header.

def _ollama_request_problems(code):
    problems = []
    for match in re.finditer(r"\.\s*open\s*\((?!\s*\))", code):
        if not re.match(r"\.\s*open\s*\(\s*\"(?:GET|POST)\"\s*,\s*OllamaChat\.endpoint\s*\(", code[match.start():]):
            problems.append(f'line {_line_of(code, match.start())}: .open( must be .open("GET"|"POST", '
                            "OllamaChat.endpoint(...)")
    for pattern, rule in (
            (r"""\[\s*["']open["']\s*\]""", "no indirect open"),
            (r"""\[\s*["']setRequestHeader["']\s*\]""", "no indirect setRequestHeader"),
            (r"\bwithCredentials\b", "no withCredentials"),
            (r"(?i)\bauthorization\b", "no Authorization header"),
            (r"(?i)\bcookie", "no cookies")):
        lines = _hits(pattern, code)
        if lines:
            problems.append(f"{rule} (lines {lines})")
    for match in re.finditer(r"\bsetRequestHeader\s*\(", code):
        if not re.match(r'setRequestHeader\s*\(\s*"Content-Type"\s*,\s*"application/json"\s*\)',
                        code[match.start():]):
            problems.append(f'line {_line_of(code, match.start())}: only setRequestHeader("Content-Type", '
                            '"application/json")')
    return problems


def test_ollama_view_requests_only_the_ollama_endpoints():
    _require_phased(OLLAMA_CHAT_VIEW)
    problems = _ollama_request_problems(_read_code(OLLAMA_CHAT_VIEW))
    assert not problems, f"{_rel(OLLAMA_CHAT_VIEW)}: {problems}"


@pytest.mark.parametrize("snippet", [
    '    function a(x) { x.open("PUT", OllamaChat.endpoint(ollamaView.address, "chat")) }',
    '    function a(x) { x.open("GET", ollamaView.address + "/api/tags") }',
    '    function a(x, m) { x.open(m, OllamaChat.endpoint(ollamaView.address, "chat")) }',
    '    function a(x) { x.open("GET", "http://127.0.0.1:11434/api/tags") }',
    '    function a(x) { x["open"]("GET", "http://evil.example/") }',
    '    function a(x) { x.setRequestHeader("Authorization", "Bearer t") }',
    '    function a(x) { x.setRequestHeader("Content-Type", "text/plain") }',
    '    function a(x, h) { x.setRequestHeader(h, "application/json") }',
    '    function a(x) { x.setRequestHeader("Cookie", "a=b") }',
    '    function a(x) { x.withCredentials = true }',
])
def test_proof_ollama_request_rule_catches(snippet):
    assert _ollama_request_problems(_inserted_view(snippet))


# P4 Model output is untrusted: every text element is PlainText, no rich text, links or images.

TEXT_ELEMENT = r"(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)?(?:Text|Label|TextEdit|TextArea|Heading|SelectableLabel)\s*\{"
PLAIN_TEXT_FORMAT = r"(?:^|[\n;])\s*textFormat\s*:\s*(?:Text|TextEdit)\s*\.\s*PlainText\s*(?=;|\n|$)"
RICH_TEXT_BANS = {
    "RichText": r"\bRichText\b",
    "StyledText": r"\bStyledText\b",
    "MarkdownText": r"\bMarkdownText\b",
    "AutoText": r"\bAutoText\b",
    "onLinkActivated": r"\bonLinkActivated\b",
    "linkActivated": r"\blinkActivated\b",
    "openUrlExternally": r"\bopenUrlExternally\b",
    "baseUrl": r"\bbaseUrl\b",
    "Image {": r"(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)?(?:Image|AnimatedImage|BorderImage)\s*\{",
    "non-plain textFormat": r"\btextFormat\s*(?::|=(?!=))(?!\s*(?:Text|TextEdit)\s*\.\s*PlainText\b)",
}


def _top_level(body):
    """The bindings of one ``{ ... }`` block with nested blocks and strings blanked."""
    blanked = _strip_comments(body, blank_strings=True)
    out = []
    depth = 0
    for char in blanked:
        if char == "{":
            depth += 1
            out.append(" ")
        elif char == "}":
            depth -= 1
            out.append(" ")
        else:
            out.append(char if depth == 1 or char == "\n" else " ")
    return "".join(out)


def _plain_text_problems(code):
    # TextField (a TextInput) has no textFormat and always shows plain text.
    problems = []
    elements = list(_blocks(code, TEXT_ELEMENT))
    for start, body in elements:
        if len(re.findall(PLAIN_TEXT_FORMAT, _top_level(body))) != 1:
            problems.append(f"line {_line_of(code, start)}: text element without "
                            "`textFormat: Text.PlainText` (or TextEdit.PlainText)")
    for name, pattern in RICH_TEXT_BANS.items():
        lines = _hits(pattern, code)
        if lines:
            problems.append(f"{name} is forbidden (lines {lines})")
    return problems


def test_ollama_view_shows_everything_as_plain_text():
    _require_phased(OLLAMA_CHAT_VIEW)
    code = _read_code(OLLAMA_CHAT_VIEW)
    problems = _plain_text_problems(code)
    assert list(_blocks(code, TEXT_ELEMENT)), f"{_rel(OLLAMA_CHAT_VIEW)}: no text elements found"
    assert not problems, f"{_rel(OLLAMA_CHAT_VIEW)}: {problems}"


@pytest.mark.parametrize("snippet", [
    "    Text { text: \"reply\" }",
    "    QQC2.Label {\n        text: \"reply\"\n    }",
    "    Kirigami.Heading { text: \"h\" }",
    "    Kirigami.SelectableLabel { text: \"r\" }",
    "    TextEdit { readOnly: true; text: \"r\"; textFormat: TextEdit.MarkdownText }",
    "    Text { text: \"r\"; textFormat: Text.AutoText }",
    "    Text { text: \"r\"; textFormat: Text.RichText }",
    "    Text { text: \"r\"; textFormat: Text.StyledText }",
    "    Text {\n        text: \"r\"\n        Text { textFormat: Text.PlainText }\n    }",
    "    Text { textFormat: Text.PlainText; onLinkActivated: (link) => Qt.openUrlExternally(link) }",
    "    TextEdit { textFormat: TextEdit.PlainText; baseUrl: \"http://127.0.0.1/\" }",
    "    Image { source: \"http://127.0.0.1:9/x\" }",
    "    function f(t) { t.textFormat = Text.RichText }",
])
def test_proof_plain_text_rule_catches(snippet):
    assert _plain_text_problems(_inserted_view(snippet))


# P4 also covers the model picker in FullRepresentation.qml: model names come
# from the server, so its delegate shows them as plain text only.

MODEL_COMBO = r"(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)?ComboBox\s*\{"
MODEL_COMBO_MODEL = r"(?:^|[\n;])\s*model\s*:\s*ollamaView\s*\.\s*modelList\s*(?=;|\n|$)"


def _model_picker_problems(code):
    pickers = [(start, body) for start, body in _blocks(code, MODEL_COMBO)
               if re.search(MODEL_COMBO_MODEL, _top_level(body))]
    if len(pickers) != 1:
        return [f"exactly one ComboBox with `model: ollamaView.modelList`, found {len(pickers)}"]
    start, body = pickers[0]
    line = _line_of(code, start)
    top = _top_level(body)
    problems = []
    if not re.search(r"(?:^|[\n;])\s*delegate\s*:", top):
        problems.append(f"line {line}: the model picker needs its own delegate (the style's shows AutoText)")
    if re.search(r"(?:^|[\n;])\s*contentItem\s*:", top):
        problems.append(f"line {line}: the model picker must keep the style's contentItem (a TextField)")
    if not list(_blocks(body, TEXT_ELEMENT)):
        problems.append(f"line {line}: no text elements in the model picker delegate")
    problems += [f"model picker (from line {line}): {problem}" for problem in _plain_text_problems(body)]
    return problems


def test_model_picker_shows_model_names_as_plain_text():
    _require_phased(OLLAMA_CHAT_VIEW)
    problems = _model_picker_problems(_read_code(FULL_REPRESENTATION))
    assert not problems, f"{_rel(FULL_REPRESENTATION)}: {problems}"


@pytest.mark.parametrize(("old", "new"), [
    ("textFormat: Text.PlainText\n                                text: modelDelegate.modelData.name",
     "text: modelDelegate.modelData.name"),
    ("textFormat: Text.PlainText\n                                visible: text !== \"\"",
     "textFormat: Text.StyledText\n                                visible: text !== \"\""),
    ("                    delegate: PlasmaComponents.ItemDelegate {\n                        id: modelDelegate",
     "                    property Component unused: PlasmaComponents.ItemDelegate {\n"
     "                        id: modelDelegate"),
    ("                    model: ollamaView.modelList\n",
     "                    model: ollamaView.modelList\n                    contentItem: Text { text: \"x\"; "
     "textFormat: Text.PlainText }\n"),
    ("                    model: ollamaView.modelList\n", "                    model: ollamaView.models\n"),
])
def test_proof_model_picker_rule_catches(old, new):
    assert _model_picker_problems(_mutated(FULL_REPRESENTATION, old, new))


# P5 The input never feeds spell checkers or IME learning.

EDITABLE_ELEMENT = r"(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)?(?:TextArea|TextField|TextEdit|TextInput)\s*\{"


def _input_privacy_problems(code):
    problems = []
    inputs = [
        (start, _top_level(body)) for start, body in _blocks(code, EDITABLE_ELEMENT)
        if not re.search(r"(?:^|[\n;])\s*readOnly\s*:\s*true\s*(?=;|\n|$)", _top_level(body))
    ]
    if not inputs:
        problems.append("no editable input found")
    for start, top in inputs:
        line = _line_of(code, start)
        if not re.search(r"(?:^|[\n;])\s*Kirigami\.SpellCheck\.enabled\s*:\s*false\s*(?=;|\n|$)", top):
            problems.append(f"line {line}: the input needs `Kirigami.SpellCheck.enabled: false`")
        hints = re.findall(r"(?:^|[\n;])\s*inputMethodHints\s*:\s*([^;\n]+)", top)
        if len(hints) != 1 or not all(re.search(rf"\bQt\.{flag}\b", hints[0])
                                      for flag in ("ImhNoPredictiveText", "ImhSensitiveData")) \
                or re.search(r"[&~^]", hints[0]):
            problems.append(f"line {line}: inputMethodHints must include Qt.ImhNoPredictiveText | Qt.ImhSensitiveData")
    for pattern, rule in ((r"\bSpellCheck\s*\.\s*enabled\s*(?::|=(?!=))(?!\s*false\b)", "spell check on"),
                          (r"\binputMethodHints\s*=(?!=)", "inputMethodHints changed at runtime")):
        lines = _hits(pattern, code)
        if lines:
            problems.append(f"{rule} (lines {lines})")
    return problems


def test_ollama_input_disables_spell_check_and_ime_learning():
    _require_phased(OLLAMA_CHAT_VIEW)
    problems = _input_privacy_problems(_read_code(OLLAMA_CHAT_VIEW))
    assert not problems, f"{_rel(OLLAMA_CHAT_VIEW)}: {problems}"


@pytest.mark.parametrize("snippet", [
    "    QQC2.TextArea { textFormat: TextEdit.PlainText }",
    "    QQC2.TextField { Kirigami.SpellCheck.enabled: false }",
    "    QQC2.TextArea {\n        textFormat: TextEdit.PlainText\n        Kirigami.SpellCheck.enabled: false\n"
    "        inputMethodHints: Qt.ImhNoPredictiveText\n    }",
    "    QQC2.TextArea {\n        textFormat: TextEdit.PlainText\n        Kirigami.SpellCheck.enabled: true\n"
    "        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData\n    }",
    "    function f() { input.inputMethodHints = Qt.ImhNone }",
])
def test_proof_input_privacy_rule_catches(snippet):
    assert _input_privacy_problems(_inserted_view(snippet))


def test_proof_input_without_any_editable_is_caught():
    assert _input_privacy_problems(_strip_comments("Item {\n    Text { textFormat: Text.PlainText }\n}\n"))


# P6 (config) lives in the persisted-configuration rules above: both Ollama
# files are in CHAT_CONFIG_READ_ONLY_FILES and chatOllamaUrl joins the key set.

def test_proof_ollama_view_config_write_is_caught():
    view = _inserted_view("    function f() { Plasmoid.configuration.chatOllamaUrl = \"http://127.0.0.1:1\" }")
    config = r"\b[Pp]lasmoid\s*\.\s*configuration(?:\s*\.\s*\w+|\s*\[[^\]]*\])+\s*=(?!=)"
    assert _hits(config, view)


def test_proof_ollama_key_with_a_different_default_is_caught():
    # The config page rule compares the declared literal with this exact text.
    assert OLLAMA_CONFIG_KEYS == {"chatOllamaUrl": ("String", "http://127.0.0.1:11434")}
    page = _strip_comments(
        'property string cfg_chatOllamaUrl: "http://0.0.0.0:11434"\n'
        'property string cfg_chatOllamaUrlDefault: "http://127.0.0.1:11434"\n')
    values = [re.findall(rf"(?m)^\s*property\s+\w+\s+{name}\s*:\s*(.+?)\s*$", page)
              for name in ("cfg_chatOllamaUrl", "cfg_chatOllamaUrlDefault")]
    assert values[0] != ['"http://127.0.0.1:11434"'] and values[1] == ['"http://127.0.0.1:11434"']


# P7 The owner check command is built only by OllamaChat.js; its reply is stdout only.

OWNER_COMMAND = (
    r'"env HEARTHSIDE_RUN="\s*\+\s*\w+\s*\+\s*" HEARTHSIDE_APPLET="\s*\+\s*\w+\s*'
    r'\+\s*" python3 -m hearthside --port-owner "\s*\+\s*\w+'
)
OTHER_HELPER_FLAGS = ("--json", "--providers", "--catalog", "--detect") + HELPER_FLAGS


def _port_owner_flag_problems(sources):
    problems = [
        f"{name}:{line} --port-owner outside OllamaChat.js"
        for name, code in sources.items() if not name.endswith("OllamaChat.js")
        for line in _hits(r"(?<![\w-])--port-owner(?![\w-])", code)
    ]
    for name, code in sources.items():
        if name.endswith("OllamaChat.js"):
            if len(_hits(r"--port-owner", code)) != 1 or len(re.findall(OWNER_COMMAND, code)) != 1:
                problems.append(f"{name}: --port-owner once, as `\"env HEARTHSIDE_RUN=\" + run + "
                                "\" HEARTHSIDE_APPLET=\" + applet + \" python3 -m hearthside --port-owner \" + port`")
            problems += [f"{name}:{line} {flag}" for flag in OTHER_HELPER_FLAGS
                         for line in _hits(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", code)]
        if name.endswith("OllamaChatView.qml"):
            problems += [f"{name}:{line} stderr" for line in _hits(r"\bstderr\b", code)]
    return problems


def test_port_owner_command_is_built_only_by_ollama_chat_js():
    _require_phased(OLLAMA_CHAT_JS)
    problems = _port_owner_flag_problems(_all_code())
    assert not problems, f"port owner check: {problems}"


@pytest.mark.parametrize("target,old,new", [
    ("js", " python3 -m hearthside --port-owner ", " python3 -m hearthside --port-owner --json "),
    ("js", '" HEARTHSIDE_APPLET=" + applet\n', '""\n'),
    ("js", "--port-owner", "--port-owne"),
])
def test_proof_port_owner_command_rule_catches(target, old, new):
    js = _mutated_source(OLLAMA_CHAT_JS, SAMPLE_OLLAMA_JS, old, new)
    assert _port_owner_flag_problems({"OllamaChat.js": js})


@pytest.mark.parametrize("snippet", [
    '    readonly property string cmd: "python3 -m hearthside --port-owner 11434"',
    '    function f(data) { return data["stderr"] }',
])
def test_proof_port_owner_view_rule_catches(snippet):
    assert _port_owner_flag_problems({"OllamaChatView.qml": _inserted_view(snippet)})


def test_proof_port_owner_flag_in_main_is_caught():
    code = _mutated(MAIN_QML, "    function chatNext() {",
                    "    function x() { return \"python3 -m hearthside --port-owner 1\" }\n    function chatNext() {")
    assert _port_owner_flag_problems({"main.qml": code})


# P8 No storage APIs anywhere; no PUT/DELETE or file: URLs in the Ollama files.

PLASMOID_STORAGE_BANS = {
    "LocalStorage": r"\bLocalStorage\b",
    "openDatabaseSync": r"\bopenDatabaseSync\b",
    "Settings {": r"\bSettings\s*\{",
    "Qt.labs.settings": r"\bQt\s*\.\s*labs\s*\.\s*settings\b",
    "FileIO": r"\bFileIO\b",
}
OLLAMA_FILE_BANS = {
    "PUT/DELETE/PATCH": r"""(?i)["']\s*(?:PUT|DELETE|PATCH)\s*["']""",
    "file: URL": r"(?i)\bfile:",
}


def _ollama_storage_offenders(sources):
    return [
        f"{name}:{line} {rule}"
        for name, code in sources.items()
        for rule, pattern in PLASMOID_STORAGE_BANS.items()
        for line in _hits(pattern, code)
    ] + [
        f"{name}:{line} {rule}"
        for name, code in sources.items() if name.endswith(("OllamaChat.js", "OllamaChatView.qml"))
        for rule, pattern in OLLAMA_FILE_BANS.items()
        for line in _hits(pattern, code)
    ]


def test_plasmoid_never_uses_local_storage_or_settings_files():
    offenders = _ollama_storage_offenders(_all_code())
    assert not offenders, f"forbidden storage in plasmoid/: {offenders}"


@pytest.mark.parametrize("name,snippet", [
    ("main.qml", "import QtQuick.LocalStorage"),
    ("main.qml", "var db = openDatabaseSync(\"x\", \"1\", \"x\", 1)"),
    ("main.qml", "Settings { property string last: \"\" }"),
    ("main.qml", "QtCore.Settings { category: \"x\" }"),
    ("main.qml", "import Qt.labs.settings"),
    ("main.qml", "FileIO { id: f }"),
    ("OllamaChatView.qml", "x.open(\"PUT\", OllamaChat.endpoint(a, \"chat\"))"),
    ("OllamaChat.js", "var LOG = \"file:///tmp/ollama.log\""),
])
def test_proof_storage_rule_catches(name, snippet):
    assert _ollama_storage_offenders({name: _strip_comments(snippet)})


# P9 The test seams are set only by tests.

SEAMS = ("createRequest", "runOwnerCheck")


def _seam_problems(sources, view_present):
    problems = []
    for name, code in sources.items():
        for seam in SEAMS:
            problems += [f"{name}:{line} {seam} assigned" for line in _hits(rf"\b{seam}\s*=(?!=)", code)]
            declarations = _hits(rf"(?m)^[ \t]*property\s+var\s+{seam}\s*:", code)
            bindings = _hits(rf"(?<![\w.]){seam}\s*:", code)
            if not name.endswith("OllamaChatView.qml"):
                problems += [f"{name}:{line} {seam} bound" for line in bindings]
            elif bindings != declarations or len(declarations) != 1:
                problems.append(f"{name}: {seam} must be declared once (`property var {seam}: ...`) "
                                "and never bound elsewhere")
    if view_present and not any(name.endswith("OllamaChatView.qml") for name in sources):
        problems.append("OllamaChatView.qml is missing")
    return problems


def test_ollama_test_seams_are_never_set_in_the_plasmoid():
    # Enforced in every phase for the other files; the view's own
    # declarations are checked once it exists.
    sources = _all_code()
    problems = _seam_problems(sources, view_present=OLLAMA_CHAT_VIEW.is_file())
    assert not problems, f"createRequest/runOwnerCheck are for tests only: {problems}"


@pytest.mark.parametrize("name,snippet", [
    ("FullRepresentation.qml", "OllamaChatView { createRequest: function () { return null } }"),
    ("FullRepresentation.qml", "ollamaView.runOwnerCheck = function (c) {}"),
    ("main.qml", "Component.onCompleted: view.createRequest = null"),
])
def test_proof_seam_rule_catches_outside_the_view(name, snippet):
    assert _seam_problems({name: _strip_comments(snippet)}, view_present=False)


@pytest.mark.parametrize("snippet", [
    "    property var createRequest: null",
    "    function f() { ollamaView.runOwnerCheck = function (c) {} }",
])
def test_proof_seam_rule_catches_inside_the_view(snippet):
    assert _seam_problems({"OllamaChatView.qml": _inserted_view(snippet)}, view_present=True)


# P10 The port owner helper reads /proc only and prints nothing itself.

NETWORK_MODULES = {
    "socket", "http", "urllib", "subprocess", "ssl", "asyncio", "selectors", "socketserver",
    "ftplib", "smtplib", "imaplib", "poplib", "xmlrpc", "multiprocessing", "ctypes", "importlib",
    "webbrowser", "shutil",
}
PROCESS_CALLS = {"system", "popen", "fork", "forkpty", "posix_spawn", "posix_spawnp"}


def _port_owner_module_problems(source):
    tree = ast.parse(source)
    problems = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                problems.append(f"line {node.lineno}: no relative imports")
                continue
            names = [node.module or ""]
        else:
            names = []
        for module in names:
            top = module.split(".")[0]
            if top not in sys.stdlib_module_names or top in NETWORK_MODULES:
                problems.append(f"line {node.lineno}: import {module} is not allowed")
        if isinstance(node, ast.Name) and node.id in {"print", "__import__", "eval", "exec", "open"}:
            problems.append(f"line {node.lineno}: {node.id} is not allowed")
        if isinstance(node, ast.Attribute) and (
                node.attr in PROCESS_CALLS or node.attr.startswith(("exec", "spawn"))
                or node.attr in {"write_text", "write_bytes", "unlink", "mkdir"}):
            problems.append(f"line {node.lineno}: .{node.attr} is not allowed")
    return problems


def _cli_print_problems(source):
    tree = ast.parse(source)
    prints = [node for node in ast.walk(tree)
              if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print"]
    writes = [node for node in ast.walk(tree)
              if isinstance(node, ast.Attribute) and node.attr in {"stdout", "stderr"}]
    problems = []
    if len(prints) != 1:
        problems.append(f"exactly one print() expected, found {len(prints)}")
    else:
        call = prints[0]
        dumps = call.args[0] if len(call.args) == 1 else None
        if call.keywords or not (isinstance(dumps, ast.Call) and isinstance(dumps.func, ast.Attribute)
                                 and dumps.func.attr == "dumps" and isinstance(dumps.func.value, ast.Name)
                                 and dumps.func.value.id == "json"):
            problems.append("the one print() must be print(json.dumps(payload, ...))")
    if writes:
        problems.append(f"no direct sys.stdout/sys.stderr use (lines {[node.lineno for node in writes]})")
    return problems


def test_port_owner_module_is_stdlib_only_and_offline():
    problems = _port_owner_module_problems(PORT_OWNER_PY.read_text(encoding="utf-8"))
    assert not problems, f"{PORT_OWNER_PY.relative_to(PLASMOID.parent)}: {problems}"


def test_cli_prints_exactly_one_json_object():
    problems = _cli_print_problems(CLI_PY.read_text(encoding="utf-8"))
    assert not problems, f"{CLI_PY.relative_to(PLASMOID.parent)}: {problems}"


@pytest.mark.parametrize("old,new", [
    ("import ipaddress\n", "import ipaddress\nimport socket\n"),
    ("import ipaddress\n", "import ipaddress\nfrom urllib import request\n"),
    ("import ipaddress\n", "import ipaddress\nimport subprocess\n"),
    ("import ipaddress\n", "import ipaddress\nimport http.client\n"),
    ("import ipaddress\n", "import ipaddress\nimport requests\n"),
    ("import ipaddress\n", "import ipaddress\nfrom . import http\n"),
    ("    return frozenset(trusted)\n", "    print(trusted)\n    return frozenset(trusted)\n"),
    ("    return frozenset(trusted)\n", "    os.system(\"ss -ltn\")\n    return frozenset(trusted)\n"),
])
def test_proof_port_owner_module_rule_catches(old, new):
    raw = PORT_OWNER_PY.read_text(encoding="utf-8")
    assert old in raw
    assert _port_owner_module_problems(raw.replace(old, new, 1))


@pytest.mark.parametrize("old,new", [
    ("    return 0\n\n\ndef _helper_reply", "    print(payload)\n    return 0\n\n\ndef _helper_reply"),
    ('print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))', "print(payload)"),
    ("    return 0\n\n\ndef _helper_reply", "    sys.stdout.write(\"\\n\")\n    return 0\n\n\ndef _helper_reply"),
])
def test_proof_cli_print_rule_catches(old, new):
    raw = CLI_PY.read_text(encoding="utf-8")
    assert old in raw
    assert _cli_print_problems(raw.replace(old, new, 1))


# P11 Ollama is not a web site: the ChatSites.js `sites` literal stays the seven web ids.

def _site_ids_problems(source):
    literal = _sites_literal(_strip_comments(source))
    ids = re.findall(r"""[{,]\s*["']?id["']?\s*:\s*["']([^"']+)["']""", literal)
    # Labels may name Ollama (the Local site fronts it); ids may not.
    if ids != EXPECTED_SITE_IDS or "ollama" in ids:
        return [f"site ids must stay {EXPECTED_SITE_IDS}, got {ids}"]
    return []


def test_chat_sites_literal_has_no_ollama_entry():
    problems = _site_ids_problems(CHAT_SITES_JS.read_text(encoding="utf-8"))
    assert not problems, f"{_rel(CHAT_SITES_JS)}: {problems}"


def test_proof_ollama_site_in_chat_sites_is_caught():
    raw = CHAT_SITES_JS.read_text(encoding="utf-8")
    old = "        id: \"local\",\n"
    assert old in raw
    assert _site_ids_problems(raw.replace(old, "        id: \"ollama\",\n", 1))
    blanked = _strip_comments(raw, blank_strings=True)
    end = _sites_literal(raw)
    start = raw.index(end)
    tail = start + len(end) - 1
    assert blanked[tail] == "]"
    added = raw[:tail] + "    { id: \"ollama\", name: \"Ollama\", url: \"http://127.0.0.1:11434\" },\n" + raw[tail:]
    assert _site_ids_problems(added)


# P12 The owner check gates every request. The functions that send, and the
# one that takes the check's result, are reached only along the gate:
# ownerSource.onNewData (parsed stdout) → ownerDone → afterOwnerCheck →
# probeVersion / startChat / unloadModels; checkOwner and checkTimer may end
# a check (fail closed) through afterOwnerCheck too.

OWNER_GATE_CALLERS = {
    "runOwnerCheck": {"checkOwner"},
    "ownerDone": {"ownerSource.onNewData"},
    "afterOwnerCheck": {"checkOwner", "ownerDone", "checkTimer.onTriggered"},
    "probeVersion": {"afterOwnerCheck"},
    "listModels": {"probeVersion"},
    "fetch": {"probeVersion", "listModels"},
    "startChat": {"afterOwnerCheck"},
    "unloadModels": {"afterOwnerCheck"},
}
OWNER_GATE_HANDLERS = (
    ("ownerSource.onNewData", r"(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)?DataSource\s*\{", "ownerSource", "onNewData"),
    ("checkTimer.onTriggered", r"(?<![\w.])Timer\s*\{", "checkTimer", "onTriggered"),
)
OWNER_DONE_CALL = (
    r'ollamaView\s*\.\s*ownerDone\s*\(\s*source\s*,\s*OllamaChat\s*\.\s*parseOwnerReply\s*\(\s*'
    r'data\s*\[\s*"exit code"\s*\]\s*,\s*data\s*\[\s*"stdout"\s*\]\s*\)\s*\)'
)
RUN_OWNER_CHECK_DEFAULT = (
    r"(?m)^[ \t]*property\s+var\s+runOwnerCheck\s*:\s*function\s*\(\s*command\s*\)\s*\{\s*"
    r"ownerSource\s*\.\s*connectSource\s*\(\s*command\s*\)\s*;?\s*\}\s*$"
)


def _brace_end(blanked, start):
    """The offset just past the block whose ``{`` is at ``start``."""
    depth = 0
    for index in range(start, len(blanked)):
        if blanked[index] == "{":
            depth += 1
        elif blanked[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(blanked)


def _handler_spans(blanked, opener, object_id, handler):
    """Spans of ``handler`` at the top level of each ``opener`` block with ``id: object_id``."""
    spans = []
    for match in re.finditer(opener, blanked):
        start = blanked.find("{", match.end() - 1)
        body = blanked[start:_brace_end(blanked, start)]
        top = _top_level(body)
        if not re.search(rf"(?:^|[\n;])\s*id\s*:\s*{object_id}\s*(?=;|\n|$)", top):
            continue
        for found in re.finditer(rf"\b{handler}\s*:\s*(?:\([^)]*\)\s*=>\s*)?\{{", body):
            if top[found.start()] != " ":
                brace = start + found.end() - 1
                spans.append((brace, _brace_end(blanked, brace)))
    return spans


def _owner_gate_problems(code):
    blanked = _strip_comments(code, blank_strings=True)
    problems = []
    spans = []
    definitions = {}
    for match in re.finditer(r"\bfunction\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*\{", blanked):
        spans.append((match.start(), _brace_end(blanked, match.end() - 1), match.group(1)))
        definitions.setdefault(match.group(1), []).append(match.start(1))
    for label, opener, object_id, handler in OWNER_GATE_HANDLERS:
        found = _handler_spans(blanked, opener, object_id, handler)
        if len(found) != 1:
            problems.append(f"{label}: expected exactly one such handler, found {len(found)}")
        spans += [(start, end, label) for start, end in found]

    def caller(offset):
        around = [span for span in spans if span[0] <= offset < span[1]]
        return min(around, key=lambda span: span[1] - span[0])[2] if around else None

    for name, allowed in OWNER_GATE_CALLERS.items():
        defined = definitions.get(name, [])
        if name != "runOwnerCheck" and len(defined) != 1:
            problems.append(f"`function {name}(` must be defined exactly once, found {len(defined)}")
        calls = 0
        for match in re.finditer(rf"(?<![\w$]){name}(?![\w$])", blanked):
            line = _line_of(code, match.start())
            if match.start() in defined:
                continue
            if name == "runOwnerCheck" and re.search(r"\bproperty\s+var\s+$",
                                                     blanked[blanked.rfind("\n", 0, match.start()) + 1:match.start()]):
                continue
            if not re.match(r"\s*\(", blanked[match.end():]):
                problems.append(f"line {line}: {name} may only be called directly, not passed around")
                continue
            calls += 1
            where = caller(match.start())
            if where not in allowed:
                problems.append(f"line {line}: {name}() called from {where or 'outside any function'}; "
                                f"only from {sorted(allowed)}")
        if calls == 0:
            problems.append(f"{name}() is never called along the gate")
    names = "|".join(OWNER_GATE_CALLERS)
    for line in _hits(rf"""["'`]\s*(?:{names})\s*["'`]""", code):
        problems.append(f"line {line}: a gate function named in a string (indirect call)")
    for start, end in _handler_spans(blanked, *OWNER_GATE_HANDLERS[0][1:]):
        if len(re.findall(OWNER_DONE_CALL, code[start:end])) != 1:
            problems.append("ownerSource.onNewData must call ollamaView.ownerDone(source, "
                            'OllamaChat.parseOwnerReply(data["exit code"], data["stdout"]))')
    if len(_hits(RUN_OWNER_CHECK_DEFAULT, code)) != 1:
        problems.append("runOwnerCheck must default to `function (command) { ownerSource.connectSource(command) }`")
    if len(_hits(r"\bconnectSource\s*\(", blanked)) != 1:
        problems.append("connectSource( only once, in the runOwnerCheck default")
    return problems


def test_owner_check_gates_every_request():
    _require_phased(OLLAMA_CHAT_VIEW)
    problems = _owner_gate_problems(_read_code(OLLAMA_CHAT_VIEW))
    assert not problems, f"{_rel(OLLAMA_CHAT_VIEW)}: {problems}"


@pytest.mark.parametrize(("old", "new"), [
    # A reply that wasn't parsed from the helper's stdout.
    ('ollamaView.ownerDone(source, OllamaChat.parseOwnerReply(data["exit code"], data["stdout"]))',
     'ollamaView.ownerDone(source, { ok: true, owner: "self" })'),
    # ownerDone from anywhere else.
    ("        ollamaView.focusLater()\n    }\n    onSiteEnabledChanged: {",
     "        ollamaView.focusLater()\n        ollamaView.ownerDone(ollamaView.ownerSourceName, null)\n"
     "    }\n    onSiteEnabledChanged: {"),
    # Skipping the check.
    ('        ollamaView.checkOwner("send")\n', '        ollamaView.afterOwnerCheck("send", "")\n'),
    ('        ollamaView.checkOwner("send")\n', "        ollamaView.startChat()\n"),
    ('        ollamaView.checkOwner("load")\n', "        ollamaView.probeVersion()\n"),
    ('            ollamaView.checkOwner("unload")\n', "            ollamaView.unloadModels(names)\n"),
    ("            ollamaView.load()\n    }\n\n    // --- requests",
     "            ollamaView.fetch(\"tags\", function () {})\n    }\n\n    // --- requests"),
    # A check that times out somewhere else must not reach afterOwnerCheck.
    ("        id: checkTimer\n", "        id: ownerTimer\n"),
    # The default seam must run the real helper.
    ("function (command) { ownerSource.connectSource(command) }",
     'function (command) { ollamaView.ownerDone(command, { ok: true, owner: "self" }) }'),
])
def test_proof_owner_gate_rule_catches(old, new):
    assert _owner_gate_problems(_mutated(OLLAMA_CHAT_VIEW, old, new))


@pytest.mark.parametrize("snippet", [
    "    function later() { Qt.callLater(ollamaView.startChat) }",
    "    function later() { ollamaView[\"startChat\"]() }",
    "    function startChat() {}",
    "    function sneak() { ollamaView.unloadModels([\"llama3:latest\"]) }",
    "    Component.onCompleted: ollamaView.probeVersion()",
    "    function again(c) { ownerSource.connectSource(c) }",
])
def test_proof_owner_gate_rule_catches_insertions(snippet):
    assert _owner_gate_problems(_inserted_view(snippet))
