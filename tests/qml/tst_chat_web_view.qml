import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// ChatWebView's Local owner gate with a real, off-the-record Qt WebEngine
// view and a fake port owner helper. The Local address is 127.0.0.1:9,
// where nothing listens: no page is ever served and nothing leaves this
// computer.
TestCase {
    id: testCase
    name: "ChatWebView"
    width: 400
    height: 400
    visible: true
    when: windowShown

    // Plasma injects i18n(); a stand-in that fills %1, %2...
    function i18n(text) {
        var result = text
        for (var index = 1; index < arguments.length; index++)
            result = result.replace("%" + index, String(arguments[index]))
        return result
    }

    readonly property string home: "http://127.0.0.1:9/"
    property var commands: []

    Component {
        id: webComponent
        ChatWebView {
            anchors.fill: parent
        }
    }

    function init() {
        testCase.commands = []
    }

    function ownerCheck(web) {
        for (var index = 0; index < web.children.length; index++) {
            if (web.children[index].objectName === "localOwnerCheck")
                return web.children[index]
        }
        return null
    }

    // A Local web view with the fake helper, before any site is chosen.
    function make() {
        var web = createTemporaryObject(webComponent, testCase, {})
        verify(web !== null)
        var check = ownerCheck(web)
        verify(check !== null)
        check.runOwnerCheck = function (command) { testCase.commands.push(command) }
        web.customUrls = { local: testCase.home }
        web.siteIds = ["local", "claude"]
        web.siteId = "local"
        return web
    }

    function answer(web, owner) {
        var check = ownerCheck(web)
        verify(check.busy, "no owner check is running")
        check.ownerDone(check.sourceName, { ok: true, owner: owner })
    }

    function waitForCheck(count) {
        tryVerify(function () { return testCase.commands.length === count }, 3000,
                  "expected " + count + " owner checks, got " + testCase.commands.length)
        verify(/ --port-owner 9$/.test(testCase.commands[count - 1]), testCase.commands[count - 1])
    }

    // Addresses the view really tried to reach. A rejected navigation ends
    // as an abort (-3) or not at all; a load that went out fails with
    // "connection refused", as nothing listens on port 9. (The url property
    // already shows a rejected address, so it proves nothing.)
    property var tried: []

    function watch(view) {
        view.loadingChanged.connect(function (info) {
            if (info.errorCode !== 0 && info.errorCode !== -3)
                testCase.tried.push(info.url.toString())
        })
    }

    function waitForTry(url) {
        tryVerify(function () { return testCase.tried.indexOf(url) >= 0 }, 5000, "never tried " + url)
    }

    // No Local view exists before the helper answered self or system.
    function test_localViewIsCreatedOnlyAfterAGoodCheck() {
        testCase.tried = []
        var web = make()
        waitForCheck(1)
        compare(web.currentView, null)
        answer(web, "other")
        compare(web.currentView, null)
        compare(web.localOwnerProblem, "other")
        compare(web.localOwnerPort, 9)

        web.retryLocalOwner()
        waitForCheck(2)
        compare(web.localOwnerProblem, "")
        answer(web, "none")
        compare(web.currentView, null)
        compare(web.localOwnerProblem, "not-running")

        web.retryLocalOwner()
        waitForCheck(3)
        answer(web, "self")
        verify(web.currentView !== null)
        watch(web.currentView)
        compare(web.localOwnerProblem, "")
        // The good check's pass let the first load through: no second check.
        waitForTry(testCase.home)
        compare(testCase.commands.length, 3)
    }

    // Every later main-frame navigation to this computer is checked again;
    // a bad answer blanks the page instead of loading.
    function test_everyNavigationIsCheckedAndABadAnswerBlanks() {
        testCase.tried = []
        var web = make()
        waitForCheck(1)
        answer(web, "system")
        verify(web.currentView !== null)
        var view = web.currentView
        watch(view)
        waitForTry(testCase.home)

        var next = testCase.home + "c/1"
        view.url = next
        waitForCheck(2)
        wait(200)
        compare(testCase.tried.indexOf(next), -1, "loaded before the check answered")
        answer(web, "other")
        compare(web.localOwnerProblem, "other")
        tryVerify(function () { return view.url.toString() === "about:blank" }, 5000)
        compare(view.ownerPass, "")
        wait(200)
        compare(testCase.tried.indexOf(next), -1, "loaded after a bad answer")

        // Retry goes home through the gate again; a good answer loads it once.
        testCase.tried = []
        web.retryLocalOwner()
        waitForCheck(3)
        wait(200)
        compare(testCase.tried, [])
        answer(web, "self")
        waitForTry(testCase.home)
        compare(testCase.commands.length, 3)
    }

    // A check that never answers loads nothing; the timeout fails closed.
    function test_noAnswerLoadsNothing() {
        var web = make()
        ownerCheck(web).timeout = 50
        waitForCheck(1)
        tryVerify(function () { return web.localOwnerProblem === "owner-unknown" }, 3000)
        compare(web.currentView, null)
    }

    // --- pass for "Send the form again" (N4) ----------------------------------

    // A Local view after a good first check, with its home tried.
    function makeLocalView() {
        testCase.tried = []
        var web = make()
        waitForCheck(1)
        answer(web, "self")
        verify(web.currentView !== null)
        watch(web.currentView)
        waitForTry(testCase.home)
        return web
    }

    // What localOwnerFinished gets after a checked form post.
    function grantFormPass(web, url) {
        web.ownerPending = { view: web.currentView, url: url, port: 9, form: true, create: false }
        web.localOwnerFinished(9, "")
        compare(web.localOwnerProblem, "resend")
        compare(web.currentView.ownerPass, url)
    }

    function test_formPassExpires() {
        var web = makeLocalView()
        web.ownerPassLifetime = 200
        grantFormPass(web, testCase.home + "form")
        tryVerify(function () { return web.currentView.ownerPass === "" }, 3000)
        compare(web.localOwnerProblem, "")
    }

    // Even if the timer is late, a stale pass doesn't count: a new check.
    function test_staleFormPassIsNotUsed() {
        var web = makeLocalView()
        var next = testCase.home + "form"
        grantFormPass(web, next)
        web.currentView.ownerPassExpires = Date.now() - 1
        web.currentView.url = next
        waitForCheck(2)
        wait(200)
        compare(testCase.tried.indexOf(next), -1, "a stale pass let the load through")
    }

    function test_formPassEndsOnDismissAndOnAProblem() {
        var web = makeLocalView()
        grantFormPass(web, testCase.home + "form")
        web.dismissLocalOwner()
        compare(web.currentView.ownerPass, "")
        compare(web.localOwnerProblem, "")

        grantFormPass(web, testCase.home + "form")
        web.ownerPending = { view: web.currentView, url: testCase.home + "x", port: 9, form: false, create: false }
        web.localOwnerFinished(9, "other")
        compare(web.localOwnerProblem, "other")
        compare(web.currentView.ownerPass, "")
    }

    // --- open in browser prompt (N1) ------------------------------------------

    function test_pageRequestsOnlyAsk() {
        var web = createTemporaryObject(webComponent, testCase, {})
        verify(web !== null)
        web.externalPromptGap = 100
        web.askExternal("https://example.net/a?x=1")
        compare(web.externalUrl, "https://example.net/a?x=1")
        compare(web.externalHost, "example.net")
        // One at a time: a second request while one waits is dropped.
        web.askExternal("https://other.example/")
        compare(web.externalUrl, "https://example.net/a?x=1")
        compare(web.externalHost, "example.net")
        web.clearExternal()
        compare(web.externalUrl, "")
        compare(web.externalHost, "")
        // Rate limit: right after a prompt, requests are dropped.
        web.askExternal("https://other.example/")
        compare(web.externalUrl, "")
        wait(150)
        web.askExternal("https://other.example/")
        compare(web.externalHost, "other.example")
        web.clearExternal()
        wait(150)
        // Nothing that isn't https with a readable host.
        web.askExternal("http://example.net/")
        web.askExternal("https://ev%69l.example/")
        web.askExternal("file:///etc/passwd")
        web.askExternal("")
        compare(web.externalUrl, "")
        // Qt WebEngine hands over look-alike letters in their xn-- form,
        // and the prompt names them that way; raw ones are dropped.
        web.askExternal("https://сlaude.ai/")
        compare(web.externalUrl, "")
        web.askExternal("https://xn--laude-0ye.ai/")
        compare(web.externalHost, "xn--laude-0ye.ai")
        // Changing the site drops the prompt.
        web.siteIds = ["local"]
        web.siteId = "local"
        compare(web.externalUrl, "")
        // Open with nothing waiting opens nothing.
        web.acceptExternal()
        compare(web.externalUrl, "")
    }

    // --- sign-in window title (N5) --------------------------------------------

    function test_blankSignInWindowNamesItsOpener() {
        var web = createTemporaryObject(webComponent, testCase, {})
        verify(web !== null)
        var title = findChild(web, "overlayTitle")
        verify(title !== null)
        compare(title.textFormat, Text.PlainText)
        // The window is never loaded here; it stays blank.
        web.openOverlay({ openIn: function (view) {} }, "local", testCase.home + "chat")
        verify(web.overlayOpen)
        compare(web.overlayTitle.kind, "opener")
        compare(title.text, "Window opened by 127.0.0.1")
        web.overlayView.url = "about:blank"
        tryVerify(function () { return web.overlayView.url.toString() === "about:blank" }, 3000)
        compare(title.text, "Window opened by 127.0.0.1")
        web.closeOverlay()
        web.openOverlay({ openIn: function (view) {} }, "local", "about:blank")
        compare(title.text, "Window opened by an unknown page")
        web.closeOverlay()
        verify(!web.overlayOpen)
    }
}
