"""Static checks for the Chat tab's privacy policy (docs/privacy.md, "Chat tab").

The Chat tab hosts provider websites in Qt WebEngine inside plasmashell. Its
top constraint is that nothing the user enters reaches disk, logs, argv, env
or the plasmoid config. These tests scan the plasmoid sources for the rules
that keep it that way. Comments are stripped before searching, so a comment
that names a forbidden API cannot fail a test, while real code still does.
String literals are kept: a forbidden name inside a string (for example in
``Qt.createQmlObject``) is still a real use.
"""

import json
import re
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
# Chat files that may read the plasmoid config but never write it. Only the
# settings pages persist chat values (and main.qml the profile generation).
CHAT_CONFIG_READ_ONLY_FILES = (
    "ChatSites.js", "ChatStorage.js", "ChatView.qml", "ChatWebView.qml", "FullRepresentation.qml",
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
    code = _read_code(FULL_REPRESENTATION)
    assert len(_hits(r"(?m)^\s*current\s*:\s*full\.onChat\s*&&\s*root\.expanded\s*$", code)) == 1, (
        f"{_rel(FULL_REPRESENTATION)}: ChatView must get `current: full.onChat && root.expanded`"
    )


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


def test_main_xml_adds_only_the_chat_keys():
    entries = _main_xml_entries()
    chat_keys = {name for name in entries if name.lower().startswith("chat")}
    assert chat_keys == set(CHAT_CONFIG_KEYS), (
        f"{_rel(MAIN_XML)} chat entries must be exactly {sorted(CHAT_CONFIG_KEYS)}, got {sorted(chat_keys)}"
    )
    unexpected = set(entries) - set(CHAT_CONFIG_KEYS) - PRE_CHAT_CONFIG_KEYS
    assert not unexpected, f"{_rel(MAIN_XML)} has new persisted keys besides the chat ones: {sorted(unexpected)}"
    for key, (kind, default) in sorted(CHAT_CONFIG_KEYS.items()):
        assert entries[key]["group"] == "General", f"{_rel(MAIN_XML)}: {key} must be in group General"
        assert entries[key]["type"] == kind, f"{_rel(MAIN_XML)}: {key} must have type {kind}"
        if default is not None:
            assert entries[key]["default"] == default, (
                f"{_rel(MAIN_XML)}: {key} default must be exactly {default!r}, got {entries[key]['default']!r}"
            )


@pytest.mark.parametrize("filename", CHAT_CONFIG_READ_ONLY_FILES)
def test_chat_files_never_write_the_plasmoid_config(filename):
    path = UI / filename
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
    for key, (kind, default) in CHAT_CONFIG_KEYS.items():
        qml_type = {"String": "string", "Int": "int", "Bool": "bool"}[kind]
        for name in (f"cfg_{key}", f"cfg_{key}Default"):
            declared = re.findall(rf"(?m)^\s*property\s+(\w+)\s+{name}\s*:\s*(.+)$", code)
            assert len(declared) == 1 and declared[0][0] == qml_type, (
                f"{_rel(page)} must declare `property {qml_type} {name}` once, got {declared}"
            )
    for key in ("chatSignInStorage", "chatProfileGeneration"):
        expected = '"memory"' if key == "chatSignInStorage" else "0"
        for name in (f"cfg_{key}", f"cfg_{key}Default"):
            value = re.findall(rf"(?m)^\s*property\s+\w+\s+{name}\s*:\s*(.+?)\s*$", code)
            assert value == [expected], f"{_rel(page)}: {name} must default to {expected}, got {value}"
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
