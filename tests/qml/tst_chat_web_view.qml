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

    // Plasma injects i18n(); a plain stand-in is enough here.
    function i18n(text) {
        return text
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
}
