import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// ChatView with a stub web view: when the web view starts and with which
// profile it is built. Qt WebEngine is never loaded here.
TestCase {
    id: testCase
    name: "ChatView"
    width: 400
    height: 400
    visible: true
    when: windowShown

    // Plasma injects i18n(); a plain stand-in is enough here.
    function i18n(text) {
        return text
    }

    property var requests: []
    property var builds: []
    // Read by a declared binding, like FullRepresentation's `current:`. A
    // binding that is already true at creation emits no change signal.
    property bool shownAtCreation: false

    Component {
        id: viewComponent
        ChatView {
            anchors.fill: parent
            current: testCase.shownAtCreation
            webSource: Qt.resolvedUrl("ChatWebStub.qml")
            onStorageRequest: (action) => testCase.requests.push(action)
            onWebChanged: {
                if (web)
                    testCase.builds.push({
                        staySignedIn: web.staySignedIn,
                        storagePath: web.storagePath,
                        profileName: web.profileName
                    })
            }
        }
    }

    function init() {
        testCase.shownAtCreation = false
        testCase.requests = []
        testCase.builds = []
    }

    function make(properties) {
        var view = createTemporaryObject(viewComponent, testCase, properties || {})
        verify(view !== null)
        return view
    }

    // The popup is created with Chat already shown: the page must load
    // without a tab switch.
    function test_startsWhenCurrentAtCreation() {
        testCase.shownAtCreation = true
        var view = make()
        verify(view.started)
        tryVerify(function () { return view.web !== null })
        compare(testCase.requests.indexOf("open") >= 0, true)
        compare(testCase.builds.length, 1)
        compare(testCase.builds[0].staySignedIn, false)
    }

    // Plasma may preload the popup while it is closed (current false, as
    // FullRepresentation passes `full.onChat && root.expanded`): no web view
    // may be built inside the hidden popup, only when it is first shown.
    function test_waitsUntilShown() {
        var view = make({current: false})
        wait(50)
        verify(!view.started)
        compare(view.web, null)
        view.current = true
        tryVerify(function () { return view.web !== null })
        compare(testCase.requests, ["open"])
    }

    function test_encryptedCardHidesWebUntilReady() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            card: {view: "unlock", message: ""}
        })
        verify(view.started)
        wait(50)
        compare(view.web, null)
        var card = findChild(view, "storageCard")
        verify(card !== null)
        verify(card.visible)

        view.storagePath = "/run/user/1/hearthside/vault/web/applet-1-g0"
        view.profileName = "applet-1-g0"
        view.storageReady = true
        view.card = {view: "web", message: ""}
        tryVerify(function () { return view.web !== null })
        compare(testCase.builds.length, 1)
        compare(testCase.builds[0], {
            staySignedIn: true,
            storagePath: "/run/user/1/hearthside/vault/web/applet-1-g0",
            profileName: "applet-1-g0"
        })
        verify(view.persistentActive)
        verify(!card.visible)
    }

    function test_readyWithoutPathStaysPrivate() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            storageReady: true,
            storagePath: "",
            profileName: "applet-1-g0",
            card: {view: "web", message: ""}
        })
        tryVerify(function () { return view.web !== null })
        compare(testCase.builds[0].staySignedIn, false)
        compare(testCase.builds[0].storagePath, "")
        compare(testCase.builds[0].profileName, "")
    }

    function test_memoryModeIgnoresReadyFlag() {
        var view = make({
            current: true,
            storageMode: "folder",
            storageReady: true,
            storagePath: "/x/applet-1-g0",
            profileName: "applet-1-g0"
        })
        tryVerify(function () { return view.web !== null })
        compare(testCase.builds[0].staySignedIn, false)
    }

    function test_profileChangeRebuildsTheView() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            storageReady: true,
            storagePath: "/r/hearthside/vault/web/applet-1-g0",
            profileName: "applet-1-g0"
        })
        tryVerify(function () { return view.web !== null })
        var first = view.web
        compare(first.staySignedIn, true)
        // Lock: not ready any more → the saved profile is destroyed and a
        // private one built in its place, never switched live.
        view.storageReady = false
        tryVerify(function () { return view.web !== null && view.web !== first })
        compare(view.web.staySignedIn, false)
        compare(testCase.builds.length, 2)
        compare(testCase.builds[1].staySignedIn, false)
    }

    function test_cardTearsDownTheView() {
        var view = make({current: true, storageMode: "encrypted"})
        tryVerify(function () { return view.web !== null })
        view.card = {view: "busy", message: "lock"}
        tryVerify(function () { return view.web === null })
        view.card = {view: "web", message: ""}
        tryVerify(function () { return view.web !== null })
        compare(testCase.builds.length, 2)
    }

    function test_clearRebuildsAndAsksToDeleteSavedData() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            storageReady: true,
            storagePath: "/r/hearthside/vault/web/applet-1-g0",
            profileName: "applet-1-g0"
        })
        tryVerify(function () { return view.web !== null })
        view.clearChatData()
        verify(testCase.requests.indexOf("clear-saved") >= 0)
        tryVerify(function () { return view.web !== null && !view.clearing })
        compare(testCase.builds.length, 2)
    }

    function test_clearInPrivateSessionDoesNotTouchSavedData() {
        var view = make({current: true})
        tryVerify(function () { return view.web !== null })
        view.clearChatData()
        compare(testCase.requests.indexOf("clear-saved"), -1)
        tryVerify(function () { return view.web !== null && !view.clearing })
    }

    function test_lockOnlyWithSavedProfile() {
        var view = make({current: true})
        tryVerify(function () { return view.web !== null })
        view.lockSaved()
        compare(testCase.requests.indexOf("lock"), -1)
    }

    function test_cardButtonsRequestActions() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            card: {view: "create", message: ""}
        })
        var card = findChild(view, "storageCard")
        verify(card.visible)
        view.card = {view: "unlock", message: "wrong-passphrase"}
        compare(card.message, "Wrong passphrase. Try again.")
    }

    function test_damagedCardDeletesOnlyAfterConfirming() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            card: {view: "damaged", message: ""}
        })
        var card = findChild(view, "storageCard")
        verify(card.visible)
        var button = findChild(view, "deleteDamagedButton")
        var confirm = findChild(view, "deleteDamagedConfirm")
        verify(button !== null && confirm !== null)
        verify(button.visible)
        verify(!confirm.visible)
        compare(testCase.builds.length, 0)
        button.clicked()
        verify(!button.visible)
        verify(confirm.visible)
        compare(testCase.requests.indexOf("delete-damaged"), -1)
        // Cancel asks for nothing.
        confirm.actions[1].trigger()
        verify(!confirm.visible)
        compare(testCase.requests.indexOf("delete-damaged"), -1)
        button.clicked()
        confirm.actions[0].trigger()
        verify(!confirm.visible)
        verify(testCase.requests.indexOf("delete-damaged") >= 0)
        // Leaving the damaged card forgets a pending confirmation.
        button.clicked()
        view.card = {view: "busy", message: "destroy"}
        view.card = {view: "damaged", message: ""}
        verify(button.visible)
        verify(!confirm.visible)
        view.card = {view: "damaged", message: "busy"}
        compare(card.message, "The encrypted folder is busy, perhaps used by another Hearthside widget. Try again in a moment.")
    }

    // --- Lock automatically ---------------------------------------------

    // A saved web chat, built while shown (a hidden view never starts) and
    // then hidden when `current: false` is asked for.
    function makeSaved(properties) {
        var extra = Object.assign({}, properties || {})
        var shown = extra.current !== false
        delete extra.current
        var view = make(Object.assign({
            current: true,
            storageMode: "encrypted",
            storageReady: true,
            storagePath: "/r/hearthside/vault/web/applet-1-g0",
            profileName: "applet-1-g0",
            autoLockMinutes: 1
        }, extra))
        tryVerify(function () { return view.persistentActive })
        view.current = shown
        return view
    }

    function autoLocks() {
        return testCase.requests.filter(function (action) { return action === "auto-lock" }).length
    }

    function test_autoLockNeverWhileChatIsShown() {
        var view = makeSaved()
        verify(!view.autoLockArmed)
        compare(view.idleSince, 0)
        view.idleSince = Date.now() - 3600000
        view.checkIdle()
        compare(autoLocks(), 0)
    }

    function test_autoLockAfterTheIdleTime() {
        var view = makeSaved()
        var before = Date.now()
        view.current = false
        verify(view.autoLockArmed)
        verify(view.idleSince >= before && view.idleSince <= Date.now())
        view.checkIdle()
        compare(autoLocks(), 0)
        // One minute later (wall clock, so time asleep counts too).
        view.idleSince = Date.now() - 60000
        view.checkIdle()
        compare(autoLocks(), 1)
        compare(testCase.requests.indexOf("lock"), -1)
    }

    function test_showingChatRestartsTheIdleTime() {
        var view = makeSaved({current: false})
        view.idleSince = Date.now() - 59000
        view.current = true
        compare(view.idleSince, 0)
        view.current = false
        verify(Date.now() - view.idleSince < 1000)
        view.checkIdle()
        compare(autoLocks(), 0)
    }

    function test_autoLockWaitsForHelperSteps() {
        var view = makeSaved({current: false, storageBusy: true})
        view.idleSince = Date.now() - 60000
        view.checkIdle()
        compare(autoLocks(), 0)
        verify(view.autoLockDue)
        // A dialog of the page holds it off as well.
        view.web.dialogOpen = true
        view.storageBusy = false
        wait(50)
        compare(autoLocks(), 0)
        view.web.dialogOpen = false
        view.checkIdle()
        compare(autoLocks(), 1)
        verify(!view.autoLockDue)
    }

    function test_autoLockFiresOnceHelperIsDone() {
        var view = makeSaved({current: false, storageBusy: true})
        view.idleSince = Date.now() - 60000
        view.checkIdle()
        view.storageBusy = false
        tryVerify(function () { return autoLocks() === 1 })
    }

    function test_autoLockOffForNeverAndPrivateSessions() {
        var never = makeSaved({current: false, autoLockMinutes: 0})
        verify(!never.autoLockArmed)
        never.idleSince = Date.now() - 86400000
        never.checkIdle()
        var odd = makeSaved({current: false, autoLockMinutes: 7})
        verify(!odd.autoLockArmed)
        var memory = make({current: true, autoLockMinutes: 1})
        tryVerify(function () { return memory.web !== null })
        memory.current = false
        verify(!memory.autoLockArmed)
        memory.idleSince = Date.now() - 86400000
        memory.checkIdle()
        compare(autoLocks(), 0)
    }

    function test_changingTheSettingRestartsTheIdleTime() {
        var view = makeSaved({current: false})
        view.idleSince = Date.now() - 60000
        view.autoLockMinutes = 5
        verify(Date.now() - view.idleSince < 1000)
        view.checkIdle()
        compare(autoLocks(), 0)
    }

    function test_lockedAutomaticallyCard() {
        var view = make({
            current: true,
            storageMode: "encrypted",
            card: {view: "unlock", message: "auto-locked"}
        })
        var card = findChild(view, "storageCard")
        verify(card.visible)
        compare(card.message, "Locked automatically.")
    }
}
