from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from contextlib import contextmanager
from urllib.parse import urlencode

import pytest

from hearthside.core import http
from hearthside.core.model import FailureKind, ProviderStatus
from hearthside.providers.copilot import CopilotProvider

DUMMY_TOKEN = "Bearer DUMMY-NOT-A-SECRET"


class _FakeResp:
    status = 200

    def read(self):
        return b'{"access_token":"new"}'

    @property
    def headers(self):
        return {"Content-Type": "application/json"}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_http_post_form_sends_urlencoded(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout=15.0):
        captured["data"] = req.data
        captured["ctype"] = req.headers.get("Content-type")
        captured["method"] = req.get_method()
        return _FakeResp()

    monkeypatch.setattr(http._OPENER, "open", fake_urlopen)
    payload = {"grant_type": "refresh_token", "refresh_token": "r"}
    resp = http.http_post_form("https://example.com/token", payload,
                               {"Accept": "application/json"})
    assert captured["method"] == "POST"
    assert captured["ctype"] == "application/x-www-form-urlencoded"
    assert captured["data"] == urlencode(payload).encode()
    assert resp.status == 200
    assert resp.json()["access_token"] == "new"


def test_http_post_form_uses_rfc3986_encoding(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout=15.0):
        captured["data"] = req.data
        return _FakeResp()

    monkeypatch.setattr(http._OPENER, "open", fake_urlopen)
    http.http_post_form(
        "https://example.com/token",
        [("refresh_token", "a+b c&d")],
        {},
    )
    assert captured["data"] == b"refresh_token=a%2Bb%20c%26d"


def test_http_post_json_sends_compact_json(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout=15.0):
        captured["data"] = req.data
        captured["ctype"] = req.headers.get("Content-type")
        return _FakeResp()

    monkeypatch.setattr(http._OPENER, "open", fake_urlopen)
    http.http_post_json("https://example.com/token", {"a": "b"}, {})
    assert captured["data"] == b'{"a":"b"}'
    assert captured["ctype"] == "application/json"


class _Origin(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, handler):
        super().__init__(("127.0.0.1", 0), handler)
        self.seen: list[tuple[str, str | None]] = []
        self.redirect_status = 302
        self.location = ""

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"


class _Recorder(BaseHTTPRequestHandler):
    """Second origin: records every request that reaches it."""

    def _answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.server.seen.append((self.command, self.headers.get("Authorization")))
        body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = _answer

    def log_message(self, *args):
        pass


class _Redirector(BaseHTTPRequestHandler):
    """First origin: answers every request with a redirect to the second origin."""

    def _answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.server.seen.append((self.command, self.headers.get("Authorization")))
        body = b"moved"
        self.send_response(self.server.redirect_status)
        self.send_header("Location", self.server.location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = _answer

    def log_message(self, *args):
        pass


@contextmanager
def _two_origins(status: int):
    first, second = _Origin(_Redirector), _Origin(_Recorder)
    first.redirect_status = status
    first.location = second.url + "/stolen"
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (first, second)]
    for thread in threads:
        thread.start()
    try:
        yield first, second
    finally:
        for server in (first, second):
            server.shutdown()
            server.server_close()


@pytest.fixture
def _no_proxy(monkeypatch):
    for name in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("no_proxy", "*")
    monkeypatch.setenv("NO_PROXY", "*")


REDIRECTS = (301, 302, 303, 307, 308)


@pytest.mark.parametrize("status", REDIRECTS)
def test_get_never_follows_redirects(_no_proxy, status):
    with _two_origins(status) as (first, second):
        resp = http.http_get(first.url + "/usage", {"Authorization": DUMMY_TOKEN}, timeout=5)
    assert first.seen == [("GET", DUMMY_TOKEN)]
    assert second.seen == []
    assert resp.status == status
    assert resp.body == b"moved"
    assert resp.header("location") == second.url + "/stolen"


@pytest.mark.parametrize("status", REDIRECTS)
def test_post_json_never_follows_redirects(_no_proxy, status):
    with _two_origins(status) as (first, second):
        resp = http.http_post_json(first.url + "/token", {"refresh_token": "dummy"},
                                   {"Authorization": DUMMY_TOKEN}, timeout=5)
    assert first.seen == [("POST", DUMMY_TOKEN)]
    assert second.seen == []
    assert resp.status == status


@pytest.mark.parametrize("status", REDIRECTS)
def test_post_form_never_follows_redirects(_no_proxy, status):
    with _two_origins(status) as (first, second):
        resp = http.http_post_form(first.url + "/token", {"refresh_token": "dummy"},
                                   {"Authorization": DUMMY_TOKEN}, timeout=5)
    assert first.seen == [("POST", DUMMY_TOKEN)]
    assert second.seen == []
    assert resp.status == status


def test_redirect_to_non_http_scheme_is_a_plain_response(_no_proxy):
    with _two_origins(302) as (first, second):
        first.location = "file:///etc/passwd"
        resp = http.http_get(first.url, {"Authorization": DUMMY_TOKEN}, timeout=5)
    assert resp.status == 302
    assert second.seen == []


class _Token:
    def load_token(self):
        return "DUMMY-NOT-A-SECRET"


@pytest.mark.parametrize("status", REDIRECTS)
def test_provider_classifies_redirect_as_invalid_response(_no_proxy, status):
    with _two_origins(status) as (first, second):
        provider = CopilotProvider(
            auth_store=_Token(),
            getter=lambda url, headers, **kw: http.http_get(first.url + "/copilot", headers, timeout=5),
        )
        usage = provider.fetch()
    assert second.seen == []
    assert usage.status == ProviderStatus.ERROR
    assert usage.failure_kind == FailureKind.INVALID_RESPONSE
    assert usage.error_message == f"Copilot usage request failed ({status})."
    assert "DUMMY" not in (usage.error_message or "")
