import QtQuick
import QtTest
import "../../plasmoid/contents/ui/ChatSites.js" as ChatSites

TestCase {
    name: "ChatSites"

    function nav(url, siteId, linkClicked, isMainFrame) {
        return ChatSites.classifyNavigation({
            url: url,
            siteId: siteId === undefined ? "claude" : siteId,
            linkClicked: !!linkClicked,
            isMainFrame: isMainFrame === undefined ? true : isMainFrame
        })
    }

    function popup(url, siteId, isDialog) {
        return ChatSites.classifyNewWindow({
            url: url,
            siteId: siteId === undefined ? "claude" : siteId,
            isDialog: !!isDialog
        })
    }

    function test_catalogOrderAndFields() {
        compare(ChatSites.siteIds(),
                ["claude", "chatgpt", "grok", "gemini", "copilot", "mscopilot"])
        for (var index = 0; index < ChatSites.sites.length; index++) {
            var site = ChatSites.sites[index]
            verify(site.name.length > 0)
            verify(site.url.indexOf("https://") === 0)
            verify(/^provider-[a-z]+\.svg$/.test(site.icon))
            verify(site.site_hosts.length > 0)
            verify(site.auth_hosts.length > 0)
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

    function test_enabledSites() {
        var ids = function (list) { return list.map(function (s) { return s.id }) }
        compare(ids(ChatSites.enabledSites(
            "[\"claude\",\"chatgpt\",\"grok\",\"gemini\",\"copilot\",\"mscopilot\"]")),
            ChatSites.siteIds())
        // Catalog order wins over config order; unknown ids are dropped.
        compare(ids(ChatSites.enabledSites("[\"mscopilot\",\"cursor\",\"claude\",42]")),
                ["claude", "mscopilot"])
        compare(ids(ChatSites.enabledSites("[]")), [])
        compare(ids(ChatSites.enabledSites("not json")), ChatSites.siteIds())
        compare(ids(ChatSites.enabledSites("{\"claude\":true}")), ChatSites.siteIds())
        compare(ids(ChatSites.enabledSites("")), ChatSites.siteIds())
        compare(ids(ChatSites.enabledSites(undefined)), ChatSites.siteIds())
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
            "https://[::1]/"
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

    function test_popupSize() {
        var gu = 18
        compare(ChatSites.popupSize("usage", gu, 1920, 1080), {width: 23 * gu, height: 28 * gu})
        compare(ChatSites.popupSize("usage", gu, 100, 100), {width: 23 * gu, height: 28 * gu})
        compare(ChatSites.popupSize("chat", gu, 1920, 1080), {width: 34 * gu, height: 40 * gu})
        compare(ChatSites.popupSize("chat", gu, 600, 700), {width: 600 - 2 * gu, height: 700 - 4 * gu})
        // Never below the existing popup minimums.
        compare(ChatSites.popupSize("chat", gu, 200, 200), {width: 18 * gu, height: 15 * gu})
        compare(ChatSites.popupSize("chat", gu, 0, undefined), {width: 34 * gu, height: 40 * gu})
    }
}
