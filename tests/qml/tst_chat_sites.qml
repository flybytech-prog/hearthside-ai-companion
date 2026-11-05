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

    // Clicked (userInitiated) unless clicked is false.
    function popup(url, siteId, isDialog, customUrls, clicked) {
        return ChatSites.classifyNewWindow({
            url: url,
            siteId: siteId === undefined ? "claude" : siteId,
            isDialog: !!isDialog,
            userInitiated: clicked !== false,
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

    // L1: a sign-in window opens only for a click; a script-opened one is
    // dropped, and "external" still needs the click in ChatWebView.
    function test_newWindowOverlayNeedsAClick() {
        var none = undefined
        compare(popup("https://accounts.google.com/o/oauth2/auth", "claude", false, none, false), "block")
        compare(popup("https://example.com/", "claude", true, none, false), "block")
        compare(popup("about:blank", "claude", true, none, false), "block")
        compare(popup("", "claude", true, none, false), "block")
        compare(popup("https://example.com/paper", "claude", false, none, false), "external")
        compare(ChatSites.classifyNewWindow({url: "https://accounts.google.com/", siteId: "claude"}), "block")
        compare(ChatSites.classifyNewWindow({url: "https://accounts.google.com/", siteId: "claude",
            userInitiated: "true"}), "block")
        compare(ChatSites.classifyNewWindow({url: "https://accounts.google.com/", siteId: "claude",
            userInitiated: 1}), "block")
        compare(ChatSites.classifyNewWindow({url: "https://accounts.google.com/", siteId: "claude",
            userInitiated: true}), "overlay")
        compare(ChatSites.classifyNewWindow({url: "", isDialog: true, siteId: "claude",
            userInitiated: true}), "overlay")
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

    // L5: frames, pages and windows never reach these names of this computer.
    function test_newLocalNamesAreBlocked() {
        var names = ["localhost.localdomain", "app.localhost.localdomain", "ip6-localhost",
                     "ip6-loopback", "prime"]
        for (var index = 0; index < names.length; index++) {
            var url = "https://" + names[index] + ":3998/x"
            compare(nav(url, "claude", false, true), "block", url)
            compare(nav(url, "claude", true, true), "block", url)
            compare(nav(url, "claude", false, false), "block", url)
            compare(popup(url, "claude", true), "block", url)
            compare(popup(url, "claude", false), "block", url)
        }
    }

    function test_isLocalAddress() {
        var local = ["localhost", "127.0.0.1", "[::1]", "127.0.0.2", "127.1", "0.0.0.0", "0",
                     "2130706433", "0x7f000001", "0x7f.1", "017700000001", "foo.localhost",
                     "1.2.3.4.5", "08.1.1.1", "999.1.1.1",
                     // L5: /etc/hosts names of this computer and every name
                     // without a dot (the machine's own name, LAN names).
                     "localhost.localdomain", "LOCALHOST.LOCALDOMAIN.", "app.localhost.localdomain",
                     "ip6-localhost", "ip6-loopback", "prime", "myhost", "router", "a-b_c"]
        for (var index = 0; index < local.length; index++)
            verify(ChatSites.isLocalAddress(local[index]), local[index])
        var remote = ["claude.ai", "192.168.1.5", "10.0.0.1", "8.8.8.8", "localhost.example.com",
                      "127.example.com", "localhost.localdomain.example.com", "ip6-localhost.example.com",
                      "mylocalhost.localdomain.example", "", null]
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
            ["claude", "https://localhost.localdomain/", false, "loopback-not-allowed"],
            ["claude", "https://ip6-localhost/", false, "loopback-not-allowed"],
            ["claude", "https://myhost:8443/", false, "loopback-not-allowed"],
            ["local", "https://myhost:8443/", true, ""],
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

    // Split view: wide enough for two chat sites, same height as Chat.
    function test_popupSizeSplit() {
        var gu = 18
        compare(ChatSites.popupSize("split", gu, 1920, 1080), {width: 52 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("split", gu, 1920, 1080, 1.25),
                {width: Math.round(52 * gu * 1.25), height: Math.round(40 * gu * 1.25)})
        compare(ChatSites.popupSize("split", gu, 1920, 1080, 0.8),
                {width: Math.round(52 * gu * 0.8), height: Math.round(40 * gu * 0.8)})
        // Still clamped to the screen.
        compare(ChatSites.popupSize("split", gu, 800, 600), {width: 800 - 2 * gu, height: 600 - 4 * gu})
        compare(ChatSites.popupSize("split", gu, 200, 200), {width: 18 * gu, height: 15 * gu})
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

    // The popup width around split view (FullRepresentation.fitSplit).
    function splitStep(show, popupWidth, before, repair) {
        // gu 18: split 52 gu, chat 34 gu; the window adds 12 px around it.
        return ChatSites.splitWidthStep({
            show: show, popupWidth: popupWidth, padding: 12,
            splitWidth: 52 * 18, normalWidth: 34 * 18, before: before, repair: repair
        })
    }

    function test_splitWidthStepWidens() {
        // Split shown: widen and remember the width to go back to.
        compare(splitStep(true, 400, 0), {width: 52 * 18 + 12, before: 400})
        // Already widened (or wider by hand): leave it, keep what to go back to.
        compare(splitStep(true, 52 * 18 + 12, 400), {width: 0, before: 400})
        compare(splitStep(true, 2000, 0), {width: 0, before: 0})
        // Widened again before narrowing: the first width stays.
        compare(splitStep(true, 500, 400), {width: 52 * 18 + 12, before: 400})
    }

    function test_splitWidthStepNarrows() {
        // Split hidden (Split off, Usage tab, Ollama, Chat tab hidden): back.
        compare(splitStep(false, 52 * 18 + 12, 400), {width: 400, before: 0})
        // Nothing to go back to: leave it.
        compare(splitStep(false, 700, 0), {width: 0, before: 0})
        // Closing with split shown narrows; opening again with it shown widens.
        var closed = splitStep(false, 52 * 18 + 12, 400)
        compare(splitStep(true, closed.width, closed.before), {width: 52 * 18 + 12, before: 400})
    }

    // After a Plasma restart the saved width can be the split width (the
    // size is saved before narrowing): the first open puts it back.
    function test_splitWidthStepRepairsTheFirstOpen() {
        compare(splitStep(false, 52 * 18 + 12, 0, true), {width: 34 * 18 + 12, before: 0})
        compare(splitStep(false, 52 * 18 + 13, 0, true), {width: 34 * 18 + 12, before: 0})
        compare(splitStep(false, 52 * 18 + 11, 0, true), {width: 34 * 18 + 12, before: 0})
        // Only within 1 px of the split width, only on the first open.
        compare(splitStep(false, 52 * 18 + 14, 0, true), {width: 0, before: 0})
        compare(splitStep(false, 700, 0, true), {width: 0, before: 0})
        compare(splitStep(false, 52 * 18 + 12, 0, false), {width: 0, before: 0})
        compare(splitStep(false, 52 * 18 + 12, 0), {width: 0, before: 0})
        // Never while split is shown.
        compare(splitStep(true, 52 * 18 + 12, 0, true), {width: 0, before: 0})
        // The Usage tab's width when Usage shows.
        compare(ChatSites.splitWidthStep({show: false, popupWidth: 52 * 18 + 12, padding: 12,
                                          splitWidth: 52 * 18, normalWidth: 23 * 18, repair: true}),
                {width: 23 * 18 + 12, before: 0})
        // A small screen clamps both to the same width: nothing to repair.
        compare(ChatSites.splitWidthStep({show: false, popupWidth: 600, padding: 0,
                                          splitWidth: 600, normalWidth: 600, repair: true}),
                {width: 0, before: 0})
    }

    // A size change before the first open (applyPopupSize) leaves no width
    // to go back to unless split is shown; the step then follows it.
    function test_splitWidthStepAfterSizeChange() {
        var scaled = Math.round(52 * 18 * 1.25)
        var chat = Math.round(34 * 18 * 1.25)
        compare(ChatSites.splitWidthStep({show: true, popupWidth: scaled + 12, padding: 12,
                                          splitWidth: scaled, normalWidth: chat, before: chat + 12}),
                {width: 0, before: chat + 12})
        compare(ChatSites.splitWidthStep({show: false, popupWidth: scaled + 12, padding: 12,
                                          splitWidth: scaled, normalWidth: chat, before: chat + 12}),
                {width: chat + 12, before: 0})
        // The old scale's split width is not repaired at the new scale.
        compare(ChatSites.splitWidthStep({show: false, popupWidth: 52 * 18 + 12, padding: 12,
                                          splitWidth: scaled, normalWidth: chat, repair: true}),
                {width: 0, before: 0})
    }

    // R3: with maxPadding, a widening or first-open repair waits while the
    // measured padding is outside 0..maxPadding (window not laid out yet);
    // narrowing back never waits.
    function test_splitWidthStepWaitsForAPlausiblePadding() {
        var step = function (show, padding, before, repair) {
            return ChatSites.splitWidthStep({
                show: show, popupWidth: 400, padding: padding, maxPadding: 4 * 18,
                splitWidth: 52 * 18, normalWidth: 34 * 18, before: before, repair: repair
            })
        }
        compare(step(true, 12, 0), {width: 52 * 18 + 12, before: 400})
        compare(step(true, 0, 0), {width: 52 * 18, before: 400})
        compare(step(true, 4 * 18, 0), {width: 52 * 18 + 4 * 18, before: 400})
        compare(step(true, 4 * 18 + 1, 0), {width: 0, before: 0, wait: true})
        compare(step(true, -1, 0), {width: 0, before: 0, wait: true})
        compare(step(true, -400, 300), {width: 0, before: 300, wait: true})
        compare(step(true, NaN, 0), {width: 0, before: 0, wait: true})
        compare(step(true, undefined, 0), {width: 0, before: 0, wait: true})
        compare(step(true, "x", 0), {width: 0, before: 0, wait: true})
        // The first-open repair waits too.
        compare(step(false, 500, 0, true), {width: 0, before: 0, wait: true})
        // Narrowing back goes ahead whatever the padding.
        compare(step(false, -50, 300), {width: 300, before: 0})
        compare(step(false, 9999, 300), {width: 300, before: 0})
        compare(step(false, 9999, 0), {width: 0, before: 0})
        // Without maxPadding nothing waits (old callers).
        compare(ChatSites.splitWidthStep({show: true, popupWidth: 400, padding: 9999,
                                          splitWidth: 52 * 18}), {width: 52 * 18 + 9999, before: 400})
        compare(ChatSites.splitWidthStep({show: true, popupWidth: 400, padding: -5, maxPadding: 0,
                                          splitWidth: 52 * 18}), {width: 52 * 18, before: 400})
    }

    function test_splitWidthStepOddInput() {
        compare(ChatSites.splitWidthStep(undefined), {width: 0, before: 0})
        compare(ChatSites.splitWidthStep({show: "yes", popupWidth: 400, splitWidth: 936}), {width: 0, before: 0})
        compare(ChatSites.splitWidthStep({show: true, popupWidth: "x", padding: -5, splitWidth: 936}),
                {width: 936, before: 0})
        compare(ChatSites.splitWidthStep({show: true, popupWidth: 400, splitWidth: NaN}), {width: 0, before: 0})
        compare(ChatSites.splitWidthStep({show: false, popupWidth: 400, before: Infinity}), {width: 0, before: 0})
    }

    // --- Local web UI owner check (M2) --------------------------------------

    function test_localOwnerPort() {
        var port = function (url, siteId, customUrls) {
            return ChatSites.localOwnerPort({ siteId: siteId === undefined ? "local" : siteId,
                                              customUrls: customUrls, url: url })
        }
        compare(port("http://localhost:3000/"), 3000)
        compare(port("http://127.0.0.1:8080/c/1"), 8080)
        compare(port("http://[::1]:5/"), 5)
        compare(port("http://localhost/"), 80)
        compare(port("https://localhost/"), 443)
        compare(port("https://127.0.0.1:8443/"), 8443)
        // Every spelling of this computer counts, not just the http ones.
        compare(port("https://foo.localhost:9000/"), 9000)
        compare(port("https://127.1:9001/"), 9001)
        compare(port("https://0x7f000001:9002/"), 9002)
        // L5: these names are this computer too; never loaded unchecked.
        compare(port("https://localhost.localdomain:9003/"), 9003)
        compare(port("https://app.localhost.localdomain/"), 443)
        compare(port("https://ip6-localhost:9004/"), 9004)
        compare(port("https://ip6-loopback/"), 443)
        compare(port("https://prime:8080/"), 8080)
        compare(port("https://myhost/"), 443)
        // Not this computer, not Local, or nothing to check.
        compare(port("https://example.com/"), 0)
        compare(port("https://example.com:3000/"), 0)
        compare(port("about:blank"), 0)
        compare(port("data:text/html,x"), 0)
        compare(port("http://user@localhost:3000/"), 0)
        compare(port(""), 0)
        compare(port(undefined), 0)
        compare(port("http://localhost:3000/", "claude"), 0)
        compare(port("http://localhost:3000/", "nope"), 0)
        compare(ChatSites.localOwnerPort(undefined), 0)
    }

    function test_localOwnerGate() {
        var gate = function (url, pass, isMainFrame, siteId) {
            return ChatSites.localOwnerGate({ siteId: siteId === undefined ? "local" : siteId,
                                              url: url, pass: pass, isMainFrame: isMainFrame })
        }
        compare(gate("http://localhost:3000/", ""), "check")
        compare(gate("http://localhost:3000/", undefined), "check")
        compare(gate("http://localhost:3000/", "http://localhost:3000/"), "go")
        // A pass is for exactly one address.
        compare(gate("http://localhost:3000/x", "http://localhost:3000/"), "check")
        compare(gate("https://localhost:3001/", "http://localhost:3000/"), "check")
        // Missing frame info is the main frame.
        compare(gate("http://localhost:3000/", "", undefined), "check")
        compare(gate("http://localhost:3000/", "", false), "skip")
        compare(gate("https://example.com/", ""), "skip")
        compare(gate("about:blank", ""), "skip")
        compare(gate("http://localhost:3000/", "", true, "claude"), "skip")
        compare(ChatSites.localOwnerGate(undefined), "skip")
    }

    // --- off-site notice (L2) ------------------------------------------------

    function test_punycode() {
        // RFC 3492 / IDNA samples.
        compare(ChatSites.displayHost("https://bücher.example/"), "xn--bcher-kva.example")
        compare(ChatSites.displayHost("https://münchen.de/"), "xn--mnchen-3ya.de")
        compare(ChatSites.displayHost("https://пример.рф/"), "xn--e1afmkfd.xn--p1ai")
        compare(ChatSites.displayHost("https://例え.テスト/"), "xn--r8jz45g.xn--zckzah")
        // Cyrillic look-alike of "apple": never shown as Latin letters.
        compare(ChatSites.displayHost("https://аррӏе.com/"), "xn--80ak6aa92e.com")
        compare(ChatSites.displayHost("https://😀.example/"), "xn--e28h.example")
    }

    function test_displayHost() {
        compare(ChatSites.displayHost("https://Claude.AI./new"), "claude.ai")
        compare(ChatSites.displayHost("https://user:pw@evil.example:8443/x"), "evil.example")
        compare(ChatSites.displayHost("http://[::1]:3000/"), "[::1]")
        compare(ChatSites.displayHost("https://BÜCHER.example/"), "xn--bcher-kva.example")
        compare(ChatSites.displayHost("https://a。b.example/"), "a.b.example")
        compare(ChatSites.displayHost("https://<img src=x>/"), "")
        compare(ChatSites.displayHost("https://ev%69l.example/"), "")
        compare(ChatSites.displayHost("https://a b/"), "")
        compare(ChatSites.displayHost("https://[x]/"), "")
        compare(ChatSites.displayHost("about:blank"), "")
        compare(ChatSites.displayHost("data:text/html,x"), "")
        compare(ChatSites.displayHost(undefined), "")
    }

    function off(url, siteId, customUrls) {
        return ChatSites.offSiteHost({ siteId: siteId === undefined ? "claude" : siteId,
                                       customUrls: customUrls, url: url })
    }

    function test_offSiteHostKnownHostsAreOnSite() {
        compare(off("https://claude.ai/new"), { off: false, host: "" })
        compare(off("https://www.anthropic.com/"), { off: false, host: "" })
        // Sign-in hosts are part of the site: OAuth flows show no notice.
        compare(off("https://accounts.google.com/o/oauth2"), { off: false, host: "" })
        compare(off("https://appleid.apple.com/auth"), { off: false, host: "" })
        compare(off("https://login.microsoftonline.com/x", "chatgpt"), { off: false, host: "" })
        compare(off("https://auth.openai.com/log-in", "chatgpt"), { off: false, host: "" })
        compare(off("http://localhost:3000/", "local"), { off: false, host: "" })
        // A custom address adds its exact host.
        compare(off("https://chat.example.org/", "claude", { claude: "https://chat.example.org/" }),
                { off: false, host: "" })
        // Nothing to say about blank or non-web pages.
        compare(off("about:blank"), { off: false, host: "" })
        compare(off(""), { off: false, host: "" })
        compare(off("data:text/html,x"), { off: false, host: "" })
    }

    function test_offSiteHostElsewhere() {
        compare(off("https://claude.ai.evil.example/login"), { off: true, host: "claude.ai.evil.example" })
        compare(off("https://evilclaude.ai/"), { off: true, host: "evilclaude.ai" })
        compare(off("https://сlaude.ai/"), { off: true, host: "xn--laude-0ye.ai" })
        compare(off("https://sub.chat.example.org/", "claude", { claude: "https://chat.example.org/" }),
                { off: true, host: "sub.chat.example.org" })
        compare(off("https://example.com/", "local"), { off: true, host: "example.com" })
        compare(off("https://accounts.google.com/", "copilot", {}), { off: false, host: "" })
        compare(off("https://accounts.google.com.evil/", "copilot"), { off: true, host: "accounts.google.com.evil" })
        // Unreadable host: still off, without a host.
        compare(off("https://ev%69l.example/"), { off: true, host: "" })
        // "\" is read as "/" by browsers: never the host after it.
        compare(off("https://evil.example\\@claude.ai/"), { off: true, host: "" })
        compare(off("https://claude.ai\\x/"), { off: true, host: "" })
    }

    function test_displayHostRejectsBackslashes() {
        compare(ChatSites.displayHost("https://evil.example\\@claude.ai/"), "")
        compare(ChatSites.displayHost("https://evil.example\\claude.ai/"), "")
        compare(ChatSites.displayHost("https://a\\b@claude.ai/"), "")
        // A backslash after the host (in the path) changes nothing.
        compare(ChatSites.displayHost("https://claude.ai/a\\b"), "claude.ai")
    }

    // N5: a sign-in window always names a host.
    function test_overlayHost() {
        compare(ChatSites.overlayHost({ url: "https://accounts.google.com/x", openerUrl: "https://claude.ai/" }),
                { kind: "page", host: "accounts.google.com" })
        compare(ChatSites.overlayHost({ url: "about:blank", openerUrl: "https://claude.ai/new" }),
                { kind: "opener", host: "claude.ai" })
        compare(ChatSites.overlayHost({ url: "", openerUrl: "https://Evil.Example./x" }),
                { kind: "opener", host: "evil.example" })
        compare(ChatSites.overlayHost({ url: "data:text/html,x", openerUrl: "https://сlaude.ai/" }),
                { kind: "opener", host: "xn--laude-0ye.ai" })
        compare(ChatSites.overlayHost({ url: "about:blank", openerUrl: "about:blank" }),
                { kind: "unknown", host: "" })
        compare(ChatSites.overlayHost({ url: "about:blank", openerUrl: "https://evil.example\\@claude.ai/" }),
                { kind: "unknown", host: "" })
        compare(ChatSites.overlayHost({}), { kind: "unknown", host: "" })
        compare(ChatSites.overlayHost(undefined), { kind: "unknown", host: "" })
        var long = ""
        for (var index = 0; index < 20; index++)
            long += "claude-ai-"
        var result = ChatSites.overlayHost({ url: "about:blank", openerUrl: "https://" + long + ".evil.example/" })
        compare(result.host.length, ChatSites.MAX_HOST_DISPLAY)
        verify(result.host.slice(-13) === ".evil.example")
    }

    function test_offSiteHostIsShortenedFromTheFront() {
        var long = ""
        for (var index = 0; index < 20; index++)
            long += "claude-ai-"
        var result = off("https://" + long + ".evil.example/")
        compare(result.off, true)
        compare(result.host.length, ChatSites.MAX_HOST_DISPLAY)
        compare(result.host.charAt(0), "…")
        verify(result.host.slice(-13) === ".evil.example")
    }
}
