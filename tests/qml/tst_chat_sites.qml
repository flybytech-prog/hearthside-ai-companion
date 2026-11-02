import QtQuick
import QtTest
import "../../plasmoid/contents/ui/ChatSites.js" as ChatSites

TestCase {
    name: "ChatSites"

    function nav(url, siteId, linkClicked, isMainFrame, customUrls) {
        return ChatSites.classifyNavigation({
            url: url,
            siteId: siteId === undefined ? "claude" : siteId,
            linkClicked: !!linkClicked,
            isMainFrame: isMainFrame === undefined ? true : isMainFrame,
            customUrls: customUrls
        })
    }

    function popup(url, siteId, isDialog, customUrls) {
        return ChatSites.classifyNewWindow({
            url: url,
            siteId: siteId === undefined ? "claude" : siteId,
            isDialog: !!isDialog,
            customUrls: customUrls
        })
    }

    function ids(list) {
        return list.map(function (s) { return s.id })
    }

    function checkUrl(siteId, text) {
        return ChatSites.validateCustomUrl(siteId, text)
    }

    function test_catalogOrderAndFields() {
        compare(ChatSites.siteIds(),
                ["claude", "chatgpt", "grok", "gemini", "copilot", "mscopilot", "local"])
        for (var index = 0; index < ChatSites.sites.length; index++) {
            var site = ChatSites.sites[index]
            verify(site.name.length > 0)
            if (site.id === "local")
                verify(site.url.indexOf("http://localhost") === 0)
            else
                verify(site.url.indexOf("https://") === 0, site.id)
            verify(/^provider-[a-z]+\.svg$/.test(site.icon))
            verify(site.site_hosts.length > 0)
            // Only Local has no sign-in providers.
            compare(site.auth_hosts.length === 0, site.id === "local", site.id)
            compare(site.local === true, site.id === "local", site.id)
            // Every home page must be allowed by its own navigation policy.
            compare(nav(site.url, site.id, false), "allow")
            compare(nav(site.url, site.id, true), "allow")
        }
    }

    function test_byId() {
        compare(ChatSites.byId("grok").name, "Grok")
        compare(ChatSites.byId("mscopilot").url, "https://copilot.microsoft.com/")
        compare(ChatSites.byId("devin"), null)
        compare(ChatSites.byId(""), null)
        compare(ChatSites.byId(undefined), null)
    }

    function test_defaultSiteIds() {
        compare(ChatSites.defaultSiteIds(),
                ["claude", "chatgpt", "grok", "gemini", "copilot", "mscopilot"])
        compare(ChatSites.byId("local").default_on, false)
    }

    // The web UI entry is named so it isn't mistaken for the built-in
    // Ollama chat (OllamaChat.js); its id stays "local".
    function test_localSiteLabel() {
        compare(ChatSites.byId("local").name, "Local web UI (Open WebUI)")
        compare(ChatSites.siteIds().indexOf("ollama"), -1)
    }

    function test_enabledSites() {
        var defaults = ChatSites.defaultSiteIds()
        compare(ids(ChatSites.enabledSites(
            "[\"claude\",\"chatgpt\",\"grok\",\"gemini\",\"copilot\",\"mscopilot\"]")),
            defaults)
        compare(ids(ChatSites.enabledSites(JSON.stringify(ChatSites.siteIds()))),
                ChatSites.siteIds())
        // Catalog order wins over config order; unknown ids are dropped.
        compare(ids(ChatSites.enabledSites("[\"mscopilot\",\"cursor\",\"claude\",42]")),
                ["claude", "mscopilot"])
        compare(ids(ChatSites.enabledSites("[\"local\"]")), ["local"])
        compare(ids(ChatSites.enabledSites("[]")), [])
        // Unreadable config falls back to the default-on sites, never Local.
        compare(ids(ChatSites.enabledSites("not json")), defaults)
        compare(ids(ChatSites.enabledSites("{\"claude\":true}")), defaults)
        compare(ids(ChatSites.enabledSites("")), defaults)
        compare(ids(ChatSites.enabledSites(undefined)), defaults)
        compare(ids(ChatSites.enabledSites(null)), defaults)
    }

    function test_copilotSignInUrl() {
        var copilot = ChatSites.byId("copilot")
        compare(copilot.url, "https://github.com/login?return_to=%2Fcopilot")
        compare(copilot.auth_hosts, ["github.com", "accounts.google.com", "appleid.apple.com"])
        compare(nav(copilot.url, "copilot", false), "allow")
        compare(nav("https://github.com/copilot", "copilot", true), "allow")
        compare(popup("https://accounts.google.com/o/oauth2", "copilot"), "overlay")
        compare(popup("https://appleid.apple.com/auth", "copilot"), "overlay")
    }

    function test_initialSite() {
        compare(ChatSites.initialSite(["claude", "grok"], "grok"), "grok")
        compare(ChatSites.initialSite(["chatgpt", "grok"], "claude"), "chatgpt")
        compare(ChatSites.initialSite(["chatgpt"], ""), "chatgpt")
        compare(ChatSites.initialSite([], "claude"), "")
        compare(ChatSites.initialSite(null, "claude"), "")
    }

    function test_hostMatches() {
        var list = ["claude.ai", "anthropic.com"]
        verify(ChatSites.hostMatches("claude.ai", list))
        verify(ChatSites.hostMatches("www.claude.ai", list))
        verify(ChatSites.hostMatches("a.b.anthropic.com", list))
        verify(ChatSites.hostMatches("CLAUDE.AI", list))
        verify(ChatSites.hostMatches("claude.ai.", list))
        verify(ChatSites.hostMatches("claude.ai", ["Claude.AI"]))
        verify(!ChatSites.hostMatches("evilclaude.ai", list))
        verify(!ChatSites.hostMatches("claude.ai.evil.com", list))
        verify(!ChatSites.hostMatches("ai", list))
        verify(!ChatSites.hostMatches("", list))
        verify(!ChatSites.hostMatches("claude.ai", []))
        verify(!ChatSites.hostMatches("claude.ai", null))
        verify(!ChatSites.hostMatches(null, list))
    }

    function test_navigationAllowsSiteAndSso() {
        compare(nav("https://claude.ai/chat/1"), "allow")
        compare(nav("https://CLAUDE.AI/new"), "allow")
        compare(nav("about:blank"), "allow")
        // Redirects and form posts to other https hosts are allowed.
        compare(nav("https://accounts.google.com/o/oauth2", "claude", false), "allow")
        compare(nav("https://sso.example.com/login", "claude", false), "allow")
        compare(nav("https://accounts.google.com/signin", "claude", true), "allow")
        compare(nav("https://login.live.com/", "chatgpt", true), "allow")
    }

    function test_navigationLinkClicksLeaveForBrowser() {
        compare(nav("https://example.com/docs", "claude", true), "external")
        compare(nav("https://evilclaude.ai/", "claude", true), "external")
        compare(nav("https://claude.ai.evil.com/", "claude", true), "external")
        compare(nav("https://chatgpt.com/", "claude", true), "external")
        compare(nav("https://claude.ai/", "chatgpt", true), "external")
    }

    function test_navigationBlocksSchemes() {
        var blocked = [
            "file:///etc/passwd",
            "data:text/html,<b>x</b>",
            "javascript:alert(1)",
            "view-source:https://claude.ai/",
            "chrome://settings",
            "qrc:/main.qml",
            "http://claude.ai/",
            "ftp://claude.ai/",
            "about:config",
            "blob:https://claude.ai/123"
        ]
        for (var index = 0; index < blocked.length; index++) {
            compare(nav(blocked[index], "claude", false), "block", blocked[index])
            compare(nav(blocked[index], "claude", true), "block", blocked[index])
        }
    }

    function test_navigationMalformed() {
        var malformed = [
            "",
            "claude.ai",
            "https:claude.ai",
            "https://",
            "https://user@claude.ai/",
            "https://evil.com\\@claude.ai/",
            "https://cl aude.ai/",
            "https://%63laude.ai/",
            "https://.claude.ai/",
            "https://claude..ai/",
            "https://claude.ai:99999999/",
            "https://claude.ai:0/",
            "https://claude.ai:65536/",
            "https://[::2]/",
            "https://[::1/"
        ]
        for (var index = 0; index < malformed.length; index++)
            compare(nav(malformed[index], "claude", true), "block", malformed[index])
        compare(nav(null), "block")
        compare(nav(undefined), "block")
        compare(ChatSites.classifyNavigation(null), "block")
        compare(ChatSites.classifyNavigation({url: "https://claude.ai/", siteId: "claude"}), "allow")
        compare(ChatSites.classifyNavigation({url: "file:///etc/passwd", siteId: "claude"}), "block")
        compare(ChatSites.classifyNavigation({url: "file:///etc/passwd", siteId: "claude",
            isMainFrame: undefined}), "block")
        compare(ChatSites.classifyNavigation({url: "file:///etc/passwd", siteId: "claude",
            isMainFrame: 0}), "block")
    }

    function test_navigationSubframesAndUnknownSite() {
        compare(nav("file:///etc/passwd", "claude", false, false), "allow")
        compare(nav("https://ads.example.com/", "claude", true, false), "allow")
        compare(nav("about:blank", "claude", false, false), "allow")
        compare(nav("about:srcdoc", "claude", false, false), "allow")
        compare(nav("", "claude", false, false), "allow")
        compare(nav("blob:https://claude.ai/0b1c", "claude", false, false), "allow")
        compare(nav("data:text/html,x", "claude", false, false), "allow")
        compare(nav("https://claude.ai/", "devin", false), "block")
        compare(nav("https://claude.ai/", "", false), "block")
    }

    function test_newWindow() {
        compare(popup("https://accounts.google.com/o/oauth2/auth", "claude"), "overlay")
        compare(popup("https://ACCOUNTS.google.com/", "claude"), "overlay")
        compare(popup("https://login.microsoftonline.com/x", "chatgpt"), "overlay")
        compare(popup("https://appleid.apple.com/auth", "mscopilot"), "overlay")
        compare(popup("https://example.com/", "claude", true), "overlay")
        compare(popup("about:blank", "claude", true), "overlay")
        compare(popup("", "claude", true), "overlay")
        compare(popup("https://example.com/paper", "claude"), "external")
        compare(popup("https://claude.ai/other", "claude"), "external")
        compare(popup("https://evilaccounts.google.com/", "claude"), "external")
        compare(popup("http://example.com/", "claude"), "block")
        compare(popup("http://example.com/", "claude", true), "block")
        compare(popup("javascript:alert(1)", "claude", true), "block")
        compare(popup("file:///etc/passwd", "claude", true), "block")
        compare(popup("view-source:https://claude.ai/", "claude"), "block")
        compare(popup("about:blank", "claude"), "block")
        compare(popup("https://user@accounts.google.com/", "claude", true), "block")
        compare(popup("https://accounts.google.com/", "devin", true), "block")
        compare(ChatSites.classifyNewWindow(null), "block")
    }

    function test_parseUrl() {
        compare(ChatSites.parseUrl("https://claude.ai/new"),
                {scheme: "https", host: "claude.ai", port: ""})
        compare(ChatSites.parseUrl("HTTP://LocalHost:3000/c/1"),
                {scheme: "http", host: "localhost", port: "3000"})
        compare(ChatSites.parseUrl("https://[::1]/"), {scheme: "https", host: "[::1]", port: ""})
        compare(ChatSites.parseUrl("http://[::1]:8080/x"),
                {scheme: "http", host: "[::1]", port: "8080"})
        compare(ChatSites.parseUrl("https://claude.ai:1/").port, "1")
        compare(ChatSites.parseUrl("https://claude.ai:65535/").port, "65535")
        compare(ChatSites.parseUrl("https://claude.ai:0443/").port, "443")
        compare(ChatSites.parseUrl("javascript:alert(1)"), {scheme: "javascript", host: "", port: ""})
        var invalid = [
            "https://[::2]/",
            "https://[fe80::1]/",
            "https://[::1/",
            "https://[::1]x/",
            "https://[::1]:/",
            "https://claude.ai:0/",
            "https://claude.ai:00000/",
            "https://claude.ai:65536/",
            "https://claude.ai:/",
            "https://user@claude.ai/",
            "https://a\\b.ai/",
            "https://cl%61ude.ai/",
            "https://cl aude.ai/",
            ""
        ]
        for (var index = 0; index < invalid.length; index++)
            compare(ChatSites.parseUrl(invalid[index]), null, invalid[index])
    }

    function test_isLoopbackHost() {
        verify(ChatSites.isLoopbackHost("localhost"))
        verify(ChatSites.isLoopbackHost("LOCALHOST"))
        verify(ChatSites.isLoopbackHost("localhost."))
        verify(ChatSites.isLoopbackHost("127.0.0.1"))
        verify(ChatSites.isLoopbackHost("[::1]"))
        verify(!ChatSites.isLoopbackHost("127.0.0.2"))
        verify(!ChatSites.isLoopbackHost("foo.localhost"))
        verify(!ChatSites.isLoopbackHost("localhost.example.com"))
        verify(!ChatSites.isLoopbackHost("::1"))
        verify(!ChatSites.isLoopbackHost(""))
        verify(!ChatSites.isLoopbackHost(null))
        verify(!ChatSites.isLoopbackHost(undefined))
    }

    function test_isLocalAddress() {
        var local = ["localhost", "127.0.0.1", "[::1]", "127.0.0.2", "127.1", "0.0.0.0", "0",
                     "2130706433", "0x7f000001", "0x7f.1", "017700000001", "foo.localhost",
                     "1.2.3.4.5", "08.1.1.1", "999.1.1.1"]
        for (var index = 0; index < local.length; index++)
            verify(ChatSites.isLocalAddress(local[index]), local[index])
        var remote = ["claude.ai", "192.168.1.5", "10.0.0.1", "8.8.8.8", "localhost.example.com",
                      "127.example.com", "", null]
        for (var other = 0; other < remote.length; other++)
            verify(!ChatSites.isLocalAddress(remote[other]), String(remote[other]))
    }

    function test_validateCustomUrl() {
        var cases = [
            ["local", "http://localhost:3000", true, ""],
            ["local", "http://127.0.0.1:8080/", true, ""],
            ["local", "http://[::1]:3000/", true, ""],
            ["local", "https://ai.home.example/", true, ""],
            ["local", "https://localhost/", true, ""],
            ["local", "http://192.168.1.5:3000", false, "http-not-loopback"],
            ["local", "http://ai.home.example/", false, "http-not-loopback"],
            ["claude", "https://chat.example.org/x", true, ""],
            ["claude", "http://localhost:3000", false, "scheme"],
            ["claude", "http://chat.example.org/", false, "scheme"],
            ["claude", "https://localhost/", false, "loopback-not-allowed"],
            ["claude", "https://127.0.0.1:8443/", false, "loopback-not-allowed"],
            ["claude", "https://[::1]/", false, "loopback-not-allowed"],
            ["chatgpt", "https://2130706433/", false, "loopback-not-allowed"],
            ["claude", "https://user:pw@claude.ai/", false, "userinfo"],
            ["claude", "javascript:https://user@x/", false, "scheme"],
            ["local", "http://user@localhost:3000/", false, "userinfo"],
            ["claude", "javascript:alert(1)", false, "scheme"],
            ["claude", "data:text/html,x", false, "scheme"],
            ["claude", "file:///etc/passwd", false, "scheme"],
            ["local", "file:///etc/passwd", false, "scheme"],
            ["claude", "https://chat example.org/", false, "whitespace"],
            ["claude", "https://chat.example.org/a\tb", false, "whitespace"],
            ["claude", "https://chat.example.org/\n", false, "whitespace"],
            ["claude", "https://claude.ai/\u0001", false, "whitespace"],
            ["claude", "https://claude.ai/\u0000x", false, "whitespace"],
            ["claude", "https://claude.ai/\u001f", false, "whitespace"],
            ["claude", "https://claude.ai/\u007f", false, "whitespace"],
            ["local", "http://local\u0001host:3000/", false, "whitespace"],
            ["claude", "chat.example.org", false, "malformed"],
            ["claude", "https://", false, "malformed"],
            ["claude", "https://chat..example.org/", false, "malformed"],
            ["claude", "https://[fe80::1]/", false, "malformed"],
            ["claude", "https://chat.example.org:70000/", false, "malformed"],
            ["devin", "https://chat.example.org/", false, "unknown-site"],
            ["", "https://chat.example.org/", false, "unknown-site"]
        ]
        for (var index = 0; index < cases.length; index++) {
            var row = cases[index]
            var result = checkUrl(row[0], row[1])
            compare(result.ok, row[2], row[0] + " " + row[1])
            compare(result.error, row[3], row[0] + " " + row[1])
            compare(result.url, row[2] ? row[1] : "", row[0] + " " + row[1])
        }
        compare(checkUrl("claude", ""), {ok: true, url: "", error: ""})
        compare(checkUrl("claude", undefined), {ok: true, url: "", error: ""})
        var longUrl = "https://chat.example.org/"
        while (longUrl.length < 2049)
            longUrl += "a"
        compare(longUrl.length, 2049)
        compare(checkUrl("claude", longUrl).error, "too-long")
        verify(checkUrl("claude", longUrl.slice(0, 2048)).ok)
    }

    function test_subframesNeverReachThisComputer() {
        var blocked = [
            "http://localhost:3000",
            "http://localhost:3000/",
            "https://localhost/",
            "https://127.0.0.1/",
            "https://[::1]/",
            "https://2130706433/",
            "https://foo.localhost/",
            "https://0.0.0.0/",
            "http://user@localhost/"
        ]
        for (var index = 0; index < blocked.length; index++) {
            compare(nav(blocked[index], "claude", false, false), "block", blocked[index])
            compare(nav(blocked[index], "mscopilot", true, false), "block", blocked[index])
            compare(nav(blocked[index], "devin", false, false), "block", blocked[index])
        }
        compare(nav("https://example.com", "claude", false, false), "allow")
        compare(nav("https://example.com/frame", "claude", true, false), "allow")
        compare(nav("http://example.com/", "claude", false, false), "allow")
        compare(nav("https://chat.example.org/", "claude", false, false,
            {claude: "https://chat.example.org/"}), "allow")
    }

    function test_localSubframes() {
        compare(nav("http://192.168.1.5/", "local", false, false), "block")
        compare(nav("http://example.com/", "local", false, false), "block")
        compare(nav("http://localhost:8080/", "local", false, false), "block")
        compare(nav("http://127.0.0.1:3000/", "local", false, false), "block")
        compare(nav("http://localhost:3000/x", "local", false, false), "allow")
        compare(nav("http://localhost:3000/x", "local", true, false), "allow")
        compare(nav("https://cdn.example", "local", false, false), "allow")
        compare(nav("https://localhost/", "local", false, false), "allow")
        compare(nav("about:blank", "local", false, false), "allow")
        compare(nav("blob:http://localhost:3000/0b1c", "local", false, false), "allow")
        compare(nav("data:text/html,x", "local", false, false), "allow")
        var ipv4 = {local: "http://127.0.0.1:8080/"}
        compare(nav("http://127.0.0.1:8080/f", "local", false, false, ipv4), "allow")
        compare(nav("http://localhost:3000/f", "local", false, false, ipv4), "block")
        var secure = {local: "https://ai.home.example/"}
        compare(nav("http://localhost:3000/", "local", false, false, secure), "block")
        compare(nav("https://ai.home.example/f", "local", false, false, secure), "allow")
    }

    function test_customUrlToPersistTypingSecret() {
        var target = "https://admin:1234@host.example/"
        var baselines = ["", "https://chat.example.org/"]
        for (var b = 0; b < baselines.length; b++) {
            var baseline = baselines[b]
            var at = target.indexOf("@")
            for (var length = 0; length <= target.length; length++) {
                var text = target.slice(0, length)
                var result = ChatSites.customUrlToPersist("claude", text, baseline)
                var checked = ChatSites.validateCustomUrl("claude", text)
                // Always either the valid text itself or the baseline.
                compare(result.url, checked.ok ? text : baseline, text)
                compare(result.error, checked.ok ? "" : checked.error, text)
                if (length > at) {
                    compare(result.url, baseline, text)
                    compare(result.error, "userinfo", text)
                }
                verify(result.url.indexOf("1234") < 0 || length <= at, text)
            }
        }
    }

    function test_customUrlToPersist() {
        compare(ChatSites.customUrlToPersist("claude", "", "https://chat.example.org/"),
                {url: "", error: ""})
        compare(ChatSites.customUrlToPersist("claude", "  https://a.example/  ", ""),
                {url: "https://a.example/", error: ""})
        compare(ChatSites.customUrlToPersist("claude", "https://a.example/\u0001", "https://b.example/"),
                {url: "https://b.example/", error: "whitespace"})
        compare(ChatSites.customUrlToPersist("claude", "http://a.example/", "https://b.example/"),
                {url: "https://b.example/", error: "scheme"})
        // A baseline that is itself invalid is never written back.
        compare(ChatSites.customUrlToPersist("claude", "https://x@y/", "https://localhost/"),
                {url: "", error: "userinfo"})
        compare(ChatSites.customUrlToPersist("claude", "https://x@y/", undefined),
                {url: "", error: "userinfo"})
        compare(ChatSites.customUrlToPersist("local", null, "http://localhost:8080/"),
                {url: "", error: ""})
        compare(ChatSites.customUrlToPersist("devin", "https://a.example/", ""),
                {url: "", error: "unknown-site"})
    }

    function test_customUrlsParseAndSerialize() {
        var map = {local: "http://localhost:8080/", claude: "https://chat.example.org/x"}
        var json = ChatSites.serializeCustomUrls(map)
        // Catalog order, not insertion order.
        compare(json, "{\"claude\":\"https://chat.example.org/x\",\"local\":\"http://localhost:8080/\"}")
        compare(ChatSites.parseCustomUrls(json), map)
        compare(ChatSites.serializeCustomUrls(ChatSites.parseCustomUrls(json)), json)
        // Unknown ids, invalid, empty and non-string values are dropped.
        var dirty = {
            devin: "https://devin.example/",
            chatgpt: "http://chatgpt.example/",
            grok: "",
            gemini: 42,
            copilot: "https://localhost/",
            mscopilot: "https://copilot.example.net/",
            __proto__: "https://evil.example/"
        }
        compare(ChatSites.parseCustomUrls(JSON.stringify(dirty)),
                {mscopilot: "https://copilot.example.net/"})
        compare(ChatSites.serializeCustomUrls(dirty),
                "{\"mscopilot\":\"https://copilot.example.net/\"}")
        compare(ChatSites.serializeCustomUrls({}), "{}")
        compare(ChatSites.serializeCustomUrls(null), "{}")
        compare(ChatSites.serializeCustomUrls(["https://chat.example.org/"]), "{}")
        compare(ChatSites.serializeCustomUrls({claude: "not a url"}), "{}")
        var bad = ["", "not json", "[]", "[\"https://x.example/\"]", "null", "42",
                   "\"https://x.example/\"", "{\"claude\":[\"https://x.example/\"]}"]
        for (var index = 0; index < bad.length; index++)
            compare(ChatSites.parseCustomUrls(bad[index]), {}, bad[index])
        compare(ChatSites.parseCustomUrls(undefined), {})
        compare(ChatSites.parseCustomUrls(null), {})
    }

    function test_effectiveSite() {
        compare(ChatSites.effectiveSite("devin", {}), null)
        var builtIn = ChatSites.effectiveSite("claude")
        compare(builtIn.url, "https://claude.ai/new")
        compare(builtIn.exact_hosts, [])
        compare(builtIn.http_origin, "")
        var custom = ChatSites.effectiveSite("claude", {claude: "https://Chat.Example.org/x"})
        compare(custom.url, "https://Chat.Example.org/x")
        compare(custom.exact_hosts, ["chat.example.org"])
        compare(custom.site_hosts, ChatSites.byId("claude").site_hosts)
        // Stale or invalid custom values fall back to the built-in address.
        compare(ChatSites.effectiveSite("claude", {claude: "http://chat.example.org/"}).url,
                "https://claude.ai/new")
        compare(ChatSites.effectiveSite("claude", {claude: 7}).url, "https://claude.ai/new")
        compare(ChatSites.effectiveSite("claude", "nonsense").url, "https://claude.ai/new")
        compare(ChatSites.effectiveSite("local").http_origin, "localhost:3000")
        compare(ChatSites.effectiveSite("local", {local: "http://[::1]/"}).http_origin, "[::1]:80")
        compare(ChatSites.effectiveSite("local", {local: "https://ai.home.example/"}).http_origin, "")
        // Never mutates the catalog.
        custom.site_hosts.push("evil.example")
        compare(ChatSites.byId("claude").site_hosts.indexOf("evil.example"), -1)
    }

    function test_homeUrl() {
        compare(ChatSites.homeUrl("claude"), "https://claude.ai/new")
        compare(ChatSites.homeUrl("claude", {}), "https://claude.ai/new")
        compare(ChatSites.homeUrl("claude", {claude: "https://chat.example.org/x"}),
                "https://chat.example.org/x")
        compare(ChatSites.homeUrl("claude", {claude: "https://localhost/"}), "https://claude.ai/new")
        compare(ChatSites.homeUrl("local"), "http://localhost:3000/")
        compare(ChatSites.homeUrl("local", {local: "http://127.0.0.1:8080/"}), "http://127.0.0.1:8080/")
        compare(ChatSites.homeUrl("copilot"), "https://github.com/login?return_to=%2Fcopilot")
        compare(ChatSites.homeUrl("devin"), "")
    }

    function test_customHostIsExact() {
        var custom = {claude: "https://chat.example.org/x"}
        compare(nav("https://chat.example.org/x", "claude", false, true, custom), "allow")
        compare(nav("https://chat.example.org/other", "claude", true, true, custom), "allow")
        compare(nav("https://CHAT.example.org./other", "claude", true, true, custom), "allow")
        compare(nav("https://sub.chat.example.org/", "claude", true, true, custom), "external")
        compare(nav("https://example.org/", "claude", true, true, custom), "external")
        compare(nav("https://claude.ai/new", "claude", true, true, custom), "allow")
        // The custom host belongs to its own site only.
        compare(nav("https://chat.example.org/", "chatgpt", true, true, custom), "external")
        // Without customUrls: today's behaviour.
        compare(nav("https://chat.example.org/", "claude", true), "external")
        compare(nav("https://chat.example.org/", "claude", true, true, {}), "external")
        compare(nav("https://chat.example.org/", "claude", true, true, null), "external")
    }

    function test_localHttpRule() {
        compare(nav("http://localhost:3000/", "local", true), "allow")
        compare(nav("http://localhost:3000/c/1", "local", true), "allow")
        compare(nav("http://LOCALHOST:3000/c/1", "local", false), "allow")
        compare(nav("http://localhost:8080/", "local", false), "block")
        compare(nav("http://localhost/", "local", false), "block")
        compare(nav("http://127.0.0.1:3000/", "local", false), "block")
        compare(nav("http://[::1]:3000/", "local", false), "block")
        compare(nav("http://192.168.1.2:3000/", "local", false), "block")
        compare(nav("http://example.com/", "local", false), "block")
        var ipv4 = {local: "http://127.0.0.1:8080/"}
        compare(nav("http://127.0.0.1:8080/x", "local", true, true, ipv4), "allow")
        compare(nav("http://localhost:8080/x", "local", true, true, ipv4), "block")
        compare(nav("http://localhost:3000/x", "local", true, true, ipv4), "block")
        var ipv6 = {local: "http://[::1]/"}
        compare(nav("http://[::1]/", "local", false, true, ipv6), "allow")
        compare(nav("http://[::1]:80/", "local", false, true, ipv6), "allow")
        compare(nav("http://[::1]:3000/", "local", false, true, ipv6), "block")
        // A custom https address for Local turns http off entirely.
        var secure = {local: "https://ai.home.example/"}
        compare(nav("https://ai.home.example/c/1", "local", true, true, secure), "allow")
        compare(nav("https://other.example/", "local", true, true, secure), "external")
        compare(nav("http://localhost:3000/", "local", false, true, secure), "block")
        compare(nav("http://ai.home.example/", "local", false, true, secure), "block")
        compare(nav("https://localhost/", "local", false), "allow")
        compare(nav("file:///etc/passwd", "local", false), "block")
        compare(nav("javascript:alert(1)", "local", true), "block")
    }

    function test_loopbackBlockedForOtherSites() {
        var urls = [
            "http://localhost:3000",
            "http://localhost:3000/",
            "https://localhost/",
            "https://127.0.0.1/",
            "https://127.0.0.2/",
            "https://[::1]/",
            "https://[::1]:8443/",
            "https://2130706433/",
            "https://foo.localhost/",
            "https://0.0.0.0/"
        ]
        for (var index = 0; index < urls.length; index++) {
            compare(nav(urls[index], "claude", false), "block", urls[index])
            compare(nav(urls[index], "claude", true), "block", urls[index])
            compare(nav(urls[index], "mscopilot", true), "block", urls[index])
            compare(popup(urls[index], "claude"), "block", urls[index])
            compare(popup(urls[index], "claude", true), "block", urls[index])
        }
        // Even with a (rejected) loopback custom address.
        compare(nav("https://localhost/", "claude", true, true, {claude: "https://localhost/"}),
                "block")
    }

    function test_newWindowForLocal() {
        compare(popup("http://localhost:3000/", "local"), "block")
        compare(popup("http://localhost:3000/", "local", true), "block")
        compare(popup("http://127.0.0.1:3000/x", "local", true), "block")
        compare(popup("about:blank", "local", true), "overlay")
        compare(popup("", "local", true), "overlay")
        compare(popup("https://example.com/docs", "local"), "external")
        compare(popup("https://localhost/", "local"), "external")
        var secure = {local: "https://ai.home.example/"}
        compare(popup("http://ai.home.example/", "local", true, secure), "block")
        compare(popup("https://ai.home.example/x", "local", false, secure), "external")
    }

    function test_isPageUrl() {
        var claude = ChatSites.effectiveSite("claude")
        verify(ChatSites.isPageUrl(claude, "https://claude.ai/chat/1"))
        verify(ChatSites.isPageUrl(claude, "https://example.com/"))
        verify(!ChatSites.isPageUrl(claude, "http://claude.ai/"))
        verify(!ChatSites.isPageUrl(claude, "https://localhost/"))
        verify(!ChatSites.isPageUrl(claude, "https://[::1]/"))
        verify(!ChatSites.isPageUrl(claude, "about:blank"))
        verify(!ChatSites.isPageUrl(claude, "file:///etc/passwd"))
        verify(!ChatSites.isPageUrl(claude, ""))
        var local = ChatSites.effectiveSite("local")
        verify(ChatSites.isPageUrl(local, "http://localhost:3000/c/1"))
        verify(ChatSites.isPageUrl(local, "https://localhost/"))
        verify(ChatSites.isPageUrl(local, "https://ai.home.example/"))
        verify(!ChatSites.isPageUrl(local, "http://localhost:8080/"))
        verify(!ChatSites.isPageUrl(local, "http://127.0.0.1:3000/"))
        verify(!ChatSites.isPageUrl(local, "http://192.168.1.2:3000/"))
        var secure = ChatSites.effectiveSite("local", {local: "https://ai.home.example/"})
        verify(ChatSites.isPageUrl(secure, "https://ai.home.example/c/1"))
        verify(!ChatSites.isPageUrl(secure, "http://localhost:3000/"))
        verify(!ChatSites.isPageUrl(null, "https://claude.ai/"))
    }

    function test_isHttpsUrl() {
        verify(ChatSites.isHttpsUrl("https://claude.ai/new"))
        verify(!ChatSites.isHttpsUrl("http://claude.ai/"))
        verify(!ChatSites.isHttpsUrl("about:blank"))
        verify(!ChatSites.isHttpsUrl(""))
    }

    function test_userAgent() {
        var ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "QtWebEngine/6.11.3 Chrome/134.0.6998.208 Safari/537.36"
        compare(ChatSites.userAgent(ua),
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/134.0.6998.208 Safari/537.36")
        verify(ChatSites.userAgent(ua).indexOf("Chrome/134.0.6998.208") >= 0)
        verify(ChatSites.userAgent(ua).indexOf("X11; Linux x86_64") >= 0)
        compare(ChatSites.userAgent("Mozilla/5.0 Chrome/1.0"), "Mozilla/5.0 Chrome/1.0")
        compare(ChatSites.userAgent(undefined), "")
    }

    function test_isGoogleSignInHost() {
        verify(ChatSites.isGoogleSignInHost("https://accounts.google.com/"))
        verify(ChatSites.isGoogleSignInHost("https://accounts.google.com"))
        verify(ChatSites.isGoogleSignInHost(
            "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fclaude.ai"))
        verify(ChatSites.isGoogleSignInHost("HTTPS://Accounts.Google.COM/signin"))
        verify(ChatSites.isGoogleSignInHost("https://accounts.google.com:443/o/oauth2/auth"))
        var rejected = [
            "http://accounts.google.com/",
            "wss://accounts.google.com/",
            "https:accounts.google.com/",
            "https://accounts.google.com:8443/",
            "https://accounts.google.com./",
            "https://accounts.google.com.evil.example/",
            "https://evilaccounts.google.com/",
            "https://evil-accounts.google.com/",
            "https://x.accounts.google.com/",
            "https://google.com/",
            "https://gemini.google.com/app",
            "https://accounts.google.co/",
            "https://accounts.google.com@evil.example/",
            "https://user@accounts.google.com/",
            "https://evil.example/?u=https://accounts.google.com/",
            "https://evil.example/#https://accounts.google.com",
            "https://evil.example\\@accounts.google.com/",
            "https://accounts%2egoogle.com/",
            " https://accounts.google.com/",
            "about:blank",
            "",
            undefined,
            null
        ]
        for (var index = 0; index < rejected.length; index++)
            verify(!ChatSites.isGoogleSignInHost(rejected[index]), String(rejected[index]))
    }

    function test_userAgentFor() {
        var ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "QtWebEngine/6.11.3 Chrome/134.0.6998.208 Safari/537.36"
        var stripped = ChatSites.userAgent(ua)
        var firefox = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
        compare(ChatSites.GOOGLE_SIGNIN_UA, firefox)
        compare(ChatSites.userAgentFor("https://accounts.google.com/signin", ua), firefox)
        compare(ChatSites.userAgentFor("https://claude.ai/new", ua), stripped)
        compare(ChatSites.userAgentFor("https://gemini.google.com/app", ua), stripped)
        compare(ChatSites.userAgentFor("https://accounts.google.com.evil.example/", ua), stripped)
        compare(ChatSites.userAgentFor("http://accounts.google.com/", ua), stripped)
        compare(ChatSites.userAgentFor("", ua), stripped)
        compare(ChatSites.userAgentFor(undefined, ua), stripped)
        // Lists: any page on the sign-in host wins, since the profile is shared.
        compare(ChatSites.userAgentFor(["https://claude.ai/new", "https://accounts.google.com/"], ua),
                firefox)
        compare(ChatSites.userAgentFor(["https://claude.ai/new", "about:blank"], ua), stripped)
        compare(ChatSites.userAgentFor([], ua), stripped)
        // Already stripped stays the same.
        compare(ChatSites.userAgentFor("https://claude.ai/", stripped), stripped)
    }

    function test_popupSize() {
        var gu = 18
        compare(ChatSites.popupSize("usage", gu, 1920, 1080), {width: 23 * gu, height: 28 * gu})
        // Clamped to the screen too, never below the popup minimums.
        compare(ChatSites.popupSize("usage", gu, 100, 100), {width: 18 * gu, height: 15 * gu})
        compare(ChatSites.popupSize("chat", gu, 1920, 1080), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 600, 700), {width: 600 - 2 * gu, height: 700 - 4 * gu})
        // Never below the existing popup minimums.
        compare(ChatSites.popupSize("chat", gu, 200, 200), {width: 18 * gu, height: 15 * gu})
        compare(ChatSites.popupSize("chat", gu, 0, undefined), {width: 34 * gu, height: 40 * gu})
    }

    // Settings → General → Size scales the popup, still within the screen.
    function test_popupSizeScale() {
        var gu = 18
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, 1), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, 1.25),
                {width: Math.round(34 * gu * 1.25), height: Math.round(40 * gu * 1.25)})
        compare(ChatSites.popupSize("usage", gu, 4000, 4000, 0.8),
                {width: Math.round(23 * gu * 0.8), height: Math.round(28 * gu * 0.8)})
        compare(ChatSites.popupSize("chat", gu, 1366, 768, 1.25),
                {width: Math.round(34 * gu * 1.25), height: 768 - 4 * gu})
        // Odd scales are 1.
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, 0), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, -2), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, "x"), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 4000, 4000, Infinity), {width: 34 * gu, height: 40 * gu})
        // Compact never goes below the popup minimums.
        compare(ChatSites.popupSize("usage", 10, 0, 0, 0.8), {width: 184, height: 224})
    }
}
