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
CHAT_WEB_VIEW = UI / "ChatWebView.qml"
CHAT_LOG_FREE_FILES = ("ChatSites.js", "ChatView.qml", "ChatWebView.qml", "configChat.qml", "main.qml")
# Chat files that may read the plasmoid config but never write it. Only the
# settings pages persist chat values.
CHAT_CONFIG_READ_ONLY_FILES = ("ChatSites.js", "ChatView.qml", "ChatWebView.qml")
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


# --- off-the-record profile ---------------------------------------------------


def test_chat_web_view_declares_exactly_one_off_the_record_profile():
    code = _read_code(CHAT_WEB_VIEW)
    profiles = list(_blocks(code, r"\bWebEngineProfile\s*\{"))
    assert len(profiles) == 1, (
        f"{_rel(CHAT_WEB_VIEW)} must declare exactly one WebEngineProfile, found {len(profiles)}"
    )
    _, body = profiles[0]
    required = {
        "offTheRecord: true": r"\boffTheRecord\s*:\s*true\b",
        "httpCacheType: WebEngineProfile.MemoryHttpCache":
            r"\bhttpCacheType\s*:\s*WebEngineProfile\.MemoryHttpCache\b",
        "persistentCookiesPolicy: WebEngineProfile.NoPersistentCookies":
            r"\bpersistentCookiesPolicy\s*:\s*WebEngineProfile\.NoPersistentCookies\b",
        "spellCheckEnabled: false": r"\bspellCheckEnabled\s*:\s*false\b",
    }
    missing = [name for name, pattern in required.items() if not re.search(pattern, body)]
    assert not missing, f"{_rel(CHAT_WEB_VIEW)} WebEngineProfile is missing {missing}"


FORBIDDEN_STORAGE = {
    "storageName": r"\bstorageName\b",
    "persistentStoragePath": r"\bpersistentStoragePath\b",
    "cachePath": r"\bcachePath\b",
    "offTheRecord: false": r"\boffTheRecord\s*:\s*false\b",
    "defaultProfile": r"\bdefaultProfile\b",
    "ForcePersistentCookies": r"\bForcePersistentCookies\b",
    "AllowPersistentCookies": r"\bAllowPersistentCookies\b",
    "DiskHttpCache": r"\bDiskHttpCache\b",
}


@pytest.mark.parametrize("name", sorted(FORBIDDEN_STORAGE))
def test_chat_web_view_never_uses_persistent_storage(name):
    code = _read_code(CHAT_WEB_VIEW)
    lines = _hits(FORBIDDEN_STORAGE[name], code)
    assert not lines, f"{_rel(CHAT_WEB_VIEW)} must not use {name} (persists data); lines {lines}"


def test_no_plasmoid_file_uses_persistent_webengine_storage():
    offenders = [
        f"{_rel(path)}:{line} {name}"
        for path in _code_files()
        for name, pattern in FORBIDDEN_STORAGE.items()
        for line in _hits(pattern, _read_code(path))
    ]
    assert not offenders, f"persistent WebEngine storage used outside ChatWebView.qml: {offenders}"


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


@pytest.mark.parametrize("filename", CHAT_LOG_FREE_FILES)
def test_chat_files_never_log(filename):
    path = UI / filename
    code = _read_code(path)
    lines = _hits(r"\bconsole\b", code) + _hits(r"(?<![\w.])print\s*\(", code)
    assert not lines, f"{_rel(path)} must not log (console.* or print()); lines {sorted(lines)}"


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
