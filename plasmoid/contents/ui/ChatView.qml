import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "ChatStorage.js" as ChatStorage

// Chat tab body. Qt WebEngine is only reached through the Loader below, so
// the widget keeps working (with a hint) when the module is missing, and no
// web engine starts until the Chat tab is first shown.
//
// With "Stay signed in" the web view waits behind a card until main.qml has
// verified the encrypted folder is unlocked and prepared this widget's
// profile folder. The profile kind is fixed when the view is created; any
// change destroys the view and builds a new one.
ColumnLayout {
    id: chatView

    property var siteIds: []
    property string siteId: ""
    // Validated {siteId: url} custom addresses; runtime only.
    property var customUrls: ({})
    // True while the Chat tab is shown in the open popup.
    property bool current: false

    // Saved sign-ins, all runtime state owned by main.qml.
    property string storageMode: "memory"
    // main.qml: the helper verified the unlocked folder and prepared it.
    property bool storageReady: false
    property string storagePath: ""
    property string profileName: ""
    property var card: ({view: "web", message: ""})
    property var missingTools: []
    // Message code shown in memory mode too (e.g. the old folder is in use).
    property string storageNotice: ""
    // Lock automatically (minutes, 0 = never) and whether main.qml is running
    // a helper step or waiting for a passphrase.
    property int autoLockMinutes: 0
    property bool storageBusy: false
    // Overridable by tests only.
    property url webSource: Qt.resolvedUrl("ChatWebView.qml")

    // create, unlock, private, lock, auto-lock, retry, held-open, clear-saved,
    // open, recheck, dismiss-notice, saved-session
    signal storageRequest(string action)

    property bool started: false
    property bool clearing: false
    property bool confirmingClear: false
    // Inline confirmation on the damaged-folder card.
    property bool confirmingDelete: false
    // Profile the current web view was built with; "" when there is none.
    property string builtProfile: ""

    readonly property bool encrypted: ChatStorage.normalizeMode(chatView.storageMode) === "encrypted"
    // The only way to a persistent profile: encrypted mode, a verified and
    // prepared folder, and a real path and name.
    readonly property bool persistentReady: chatView.encrypted && chatView.storageReady
        && chatView.storagePath !== "" && chatView.profileName !== ""
    readonly property string profileKey: chatView.persistentReady
        ? "saved:" + chatView.profileName : "private"
    readonly property bool webWanted: chatView.started && !chatView.clearing
        && chatView.card.view === "web"
    readonly property var web: webLoader.status === Loader.Ready ? webLoader.item : null
    readonly property bool persistentActive: !!chatView.web && chatView.web.staySignedIn === true
    readonly property bool available: chatView.web !== null
    readonly property bool dialogOpen: !!chatView.web && chatView.web.dialogOpen
    readonly property bool canGoBack: !!chatView.web && chatView.web.canGoBack
    readonly property bool canOpenExternally: !!chatView.web && chatView.web.canOpenExternally
    readonly property bool localSite: chatView.siteId === "local"
    // Idle = the saved web chat is open but not shown (popup closed, Usage or
    // Ollama shown). idleSince is the wall-clock time it was last shown, so
    // time asleep counts too; 0 while not idle.
    readonly property bool autoLockArmed: chatView.persistentActive && !chatView.current
        && ChatStorage.autoLockInterval(chatView.autoLockMinutes) > 0
    property double idleSince: 0
    // The idle time ran out while main.qml was busy: lock once it is done.
    property bool autoLockDue: false

    spacing: 0

    function goBack() {
        if (chatView.web)
            chatView.web.goBack()
    }

    function reload() {
        if (chatView.web)
            chatView.web.reload()
    }

    function home() {
        if (chatView.web)
            chatView.web.home()
    }

    function openExternally() {
        if (chatView.web)
            chatView.web.openExternally()
    }

    function focusView() {
        if (chatView.web && chatView.current)
            chatView.web.focusView()
    }

    function focusLater() {
        Qt.callLater(chatView.focusView)
    }

    // Destroying the view tree destroys the off-the-record profile with it,
    // which drops every cookie, cache entry and site storage of all sites.
    // With saved sign-ins main.qml also deletes the profile folder and locks.
    function clearChatData() {
        chatView.confirmingClear = false
        var saved = chatView.persistentActive
        if (chatView.web) {
            chatView.web.cancelDownload()
            chatView.web.closeOverlay()
        }
        chatView.clearing = true
        chatView.syncLoader()
        if (saved)
            chatView.storageRequest("clear-saved")
        gc()
        Qt.callLater(chatView.finishClear)
    }

    function lockSaved() {
        if (!chatView.persistentActive)
            return
        if (chatView.web) {
            chatView.web.cancelDownload()
            chatView.web.closeOverlay()
        }
        chatView.storageRequest("lock")
    }

    function restartIdle() {
        chatView.autoLockDue = false
        chatView.idleSince = chatView.autoLockArmed ? Date.now() : 0
    }

    function checkIdle() {
        var step = ChatStorage.autoLockStep({
            armed: chatView.autoLockArmed,
            minutes: chatView.autoLockMinutes,
            idleSince: chatView.idleSince,
            now: Date.now(),
            busy: chatView.storageBusy || chatView.dialogOpen
        })
        switch (step) {
        case "restart":
            chatView.restartIdle()
            break
        case "wait":
            chatView.autoLockDue = true
            break
        case "lock":
            // Same as the Lock button; main.qml retries a busy folder later.
            chatView.autoLockDue = false
            chatView.web.cancelDownload()
            chatView.web.closeOverlay()
            chatView.storageRequest("auto-lock")
            break
        }
    }

    // Creates, keeps or destroys the web view so it always matches
    // webWanted and profileKey. A different profile is never applied to a
    // live view: the old one is destroyed first and the new one built a
    // moment later.
    function syncLoader() {
        if (!chatView.webWanted) {
            if (webLoader.active) {
                webLoader.active = false
                chatView.builtProfile = ""
            }
            return
        }
        if (webLoader.active) {
            if (chatView.builtProfile === chatView.profileKey)
                return
            webLoader.active = false
            chatView.builtProfile = ""
            gc()
            Qt.callLater(chatView.syncLoader)
            return
        }
        chatView.builtProfile = chatView.profileKey
        webLoader.setSource(chatView.webSource, {
            staySignedIn: chatView.persistentReady,
            storagePath: chatView.persistentReady ? chatView.storagePath : "",
            profileName: chatView.persistentReady ? chatView.profileName : ""
        })
        webLoader.active = true
    }

    function finishClear() {
        gc()
        chatView.clearing = false
        chatView.focusLater()
    }

    // Untrusted file names are shown as plain text, shortened.
    function plainName(name) {
        var text = String(name || "")
        if (text.length > 60)
            text = text.slice(0, 57) + "…"
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function storageText(code) {
        switch (code) {
        case "status":
            return i18n("Checking the encrypted folder…")
        case "create":
            return i18n("Creating the encrypted folder… Answer the passphrase window.")
        case "unlock":
            return i18n("Unlocking… Answer the passphrase window.")
        case "wait":
        case "lock":
            return i18n("Locking the encrypted folder…")
        case "prepare":
        case "keep":
            return i18n("Opening your saved sign-ins…")
        case "remove":
        case "destroy":
            return i18n("Deleting saved sign-ins…")
        case "wrong-passphrase":
            return i18n("Wrong passphrase. Try again.")
        case "busy":
            return i18n("The encrypted folder is busy, perhaps used by another Hearthside widget. Try again in a moment.")
        case "lock-busy":
            return i18n("The encrypted folder is still in use, perhaps by another Hearthside widget. It was not locked.")
        case "missing-tool":
            return i18n("A required tool is missing. Install gocryptfs and try again.")
        case "exists":
            return i18n("An encrypted folder already exists. Unlock it instead.")
        case "mount-failed":
            return i18n("Couldn't open the encrypted folder safely.")
        case "prepare-failed":
            return i18n("Couldn't prepare your saved sign-ins.")
        case "remove-failed":
            return i18n("Couldn't delete the saved sign-ins. The encrypted folder was locked anyway.")
        case "cleared":
            return i18n("Chat data cleared. The encrypted folder is locked.")
        case "auto-locked":
            return i18n("Locked automatically.")
        case "damaged":
            return i18n("The encrypted folder is damaged and can't be opened.")
        case "delete-failed":
            return i18n("Couldn't delete the encrypted folder because it is still in use. Close Chat in other Hearthside widgets, then delete it in Settings → Chat → Advanced.")
        case "":
            return ""
        default:
            return i18n("Something went wrong with the encrypted folder.")
        }
    }

    function start() {
        if (chatView.started)
            return
        chatView.started = true
        chatView.storageRequest("open")
    }

    onCurrentChanged: {
        if (chatView.current) {
            chatView.start()
            chatView.focusLater()
        }
    }
    onWebWantedChanged: chatView.syncLoader()
    onProfileKeyChanged: chatView.syncLoader()
    onAutoLockArmedChanged: chatView.restartIdle()
    onAutoLockMinutesChanged: chatView.restartIdle()
    onStorageBusyChanged: {
        if (!chatView.storageBusy && chatView.autoLockDue)
            Qt.callLater(chatView.checkIdle)
    }

    // The popup may be created with Chat already shown: start right away.
    Component.onCompleted: {
        if (chatView.current) {
            chatView.start()
            chatView.focusLater()
        }
        chatView.syncLoader()
    }

    Timer {
        id: idleTimer
        interval: Math.max(1000, ChatStorage.autoLockCheckInterval(chatView.autoLockMinutes))
        repeat: true
        running: chatView.autoLockArmed
        onTriggered: chatView.checkIdle()
    }

    Connections {
        target: chatView.web
        ignoreUnknownSignals: true
        // A failing page may mean the folder went away: let main.qml check.
        function onPageFailedChanged() {
            if (chatView.web && chatView.web.pageFailed && chatView.persistentActive)
                chatView.storageRequest("recheck")
        }
    }

    PlasmaComponents.ProgressBar {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(Kirigami.Units.smallSpacing / 2) || 1
        visible: !!chatView.web && chatView.web.loading
        from: 0
        to: 1
        value: chatView.web ? chatView.web.loadProgress : 0
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: chatView.confirmingClear
        type: Kirigami.MessageType.Warning
        text: chatView.persistentActive
            ? i18n("Clear chat data? This signs you out of all chat sites, deletes your saved sign-ins and locks the encrypted folder.")
            : i18n("Clear chat data? This signs you out of all chat sites.")
        actions: [
            Kirigami.Action {
                text: i18n("Clear")
                icon.name: "edit-clear-history"
                onTriggered: chatView.clearChatData()
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: chatView.confirmingClear = false
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: chatView.storageNotice !== ""
        type: Kirigami.MessageType.Warning
        text: chatView.storageText(chatView.storageNotice)
        actions: [
            Kirigami.Action {
                text: i18n("Dismiss")
                icon.name: "dialog-close"
                onTriggered: chatView.storageRequest("dismiss-notice")
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: chatView.started && chatView.encrypted && !chatView.persistentReady
            && chatView.card.view === "web"
        type: Kirigami.MessageType.Information
        text: i18n("Private session: sign-ins won't be saved this time.")
        actions: [
            Kirigami.Action {
                text: i18n("Use saved sign-ins…")
                icon.name: "unlock"
                onTriggered: chatView.storageRequest("saved-session")
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: !!chatView.web && chatView.web.pendingDownloadName !== ""
        type: Kirigami.MessageType.Information
        // Wrapped in <p> so the escaped name is always read as rich text.
        text: "<p>" + i18n("Save \"%1\" to Downloads?",
            chatView.plainName(chatView.web ? chatView.web.pendingDownloadName : "")) + "</p>"
        actions: [
            Kirigami.Action {
                text: i18n("Save")
                icon.name: "document-save"
                onTriggered: chatView.web.saveDownload()
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: chatView.web.cancelDownload()
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: !!chatView.web && chatView.web.passkeyNotice
        type: Kirigami.MessageType.Information
        text: i18n("Passkeys aren't supported here; choose another sign-in method.")
        actions: [
            Kirigami.Action {
                text: i18n("Dismiss")
                icon.name: "dialog-close"
                onTriggered: chatView.web.passkeyNotice = false
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: !!chatView.web && chatView.web.pageCrashed
        type: Kirigami.MessageType.Error
        text: i18n("Page crashed")
        actions: [
            Kirigami.Action {
                text: i18n("Reload")
                icon.name: "view-refresh"
                onTriggered: chatView.reload()
            }
        ]
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: !!chatView.web && chatView.web.pageFailed && !chatView.web.pageCrashed
        type: Kirigami.MessageType.Warning
        // The local address itself is never shown here.
        text: chatView.localSite
            ? i18n("Couldn't load. Is your local chat server running? You can change its address in Settings → Chat → Advanced.")
            : i18n("Couldn't load this page.")
        actions: [
            Kirigami.Action {
                text: i18n("Retry")
                icon.name: "view-refresh"
                onTriggered: chatView.reload()
            }
        ]
    }

    Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        // Only syncLoader() activates this, always through setSource() with
        // the profile as initial properties.
        Loader {
            id: webLoader
            anchors.fill: parent
            active: false
            onLoaded: {
                // customUrls first: the first page load must already use them.
                webLoader.item.customUrls = Qt.binding(function () { return chatView.customUrls })
                webLoader.item.siteIds = Qt.binding(function () { return chatView.siteIds })
                webLoader.item.siteId = Qt.binding(function () { return chatView.siteId })
                chatView.focusLater()
            }
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: webLoader.status === Loader.Error && chatView.card.view === "web"
            iconName: "dialog-messages"
            text: i18n("Chat needs Qt WebEngine 6.8 or newer and Qt Quick Dialogs (packages qt6-webengine, qt6-declarative)")
        }

        // Stay signed in: shown instead of the web view until the encrypted
        // folder is unlocked, or the user picks a private session.
        ColumnLayout {
            id: storageCard
            objectName: "storageCard"
            anchors.centerIn: parent
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 26)
            visible: chatView.started && chatView.card.view !== "web"
            spacing: Kirigami.Units.largeSpacing

            readonly property string view: chatView.card.view
            readonly property string message: chatView.storageText(chatView.card.message)

            onViewChanged: chatView.confirmingDelete = false

            PlasmaComponents.BusyIndicator {
                Layout.alignment: Qt.AlignHCenter
                visible: storageCard.view === "busy"
                running: visible
            }
            Kirigami.Icon {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Kirigami.Units.iconSizes.huge
                Layout.preferredHeight: Kirigami.Units.iconSizes.huge
                visible: storageCard.view !== "busy"
                source: storageCard.view === "install" || storageCard.view === "damaged"
                    ? "dialog-warning" : "object-locked"
            }
            Kirigami.Heading {
                Layout.fillWidth: true
                level: 3
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: storageCard.view !== "busy"
                text: {
                    switch (storageCard.view) {
                    case "create":
                        return i18n("Stay signed in")
                    case "unlock":
                        return i18n("Your saved sign-ins are locked")
                    case "install":
                        return i18n("Stay signed in needs gocryptfs")
                    case "held":
                        return i18n("The encrypted folder is still open")
                    case "damaged":
                        return i18n("The encrypted folder is damaged")
                    default:
                        return i18n("Saved sign-ins aren't available")
                    }
                }
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: {
                    switch (storageCard.view) {
                    case "busy":
                        return storageCard.message
                    case "create":
                        return i18n("Your sign-ins are kept in an encrypted folder. You choose its passphrase now and enter it once per Plasma session. If you forget it, the saved data can't be recovered.")
                    case "unlock":
                        return i18n("Enter your passphrase to open them for this Plasma session.")
                    case "install":
                        return i18n("The encrypted folder for saved sign-ins needs some tools that aren't installed. Install them with this command, then check again:")
                    case "damaged":
                        return i18n("The encrypted folder is damaged and can't be opened. Delete it to start again with a new one; the sign-ins saved in it are lost.")
                    default:
                        return ""
                    }
                }
                visible: text !== ""
            }
            QQC2.TextField {
                Layout.fillWidth: true
                visible: storageCard.view === "install"
                readOnly: true
                selectByMouse: true
                horizontalAlignment: Text.AlignHCenter
                text: ChatStorage.installCommand(chatView.missingTools)
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: storageCard.view !== "busy" && storageCard.message !== ""
                color: chatView.card.message === "cleared" || chatView.card.message === "auto-locked"
                    ? Kirigami.Theme.textColor : Kirigami.Theme.negativeTextColor
                text: storageCard.message
            }
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                visible: storageCard.view !== "busy"
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    visible: storageCard.view === "create"
                    icon.name: "folder-locked"
                    text: i18n("Create encrypted folder…")
                    onClicked: chatView.storageRequest("create")
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    visible: storageCard.view === "unlock"
                    icon.name: "unlock"
                    text: chatView.card.message === "wrong-passphrase" ? i18n("Try again…") : i18n("Unlock…")
                    onClicked: chatView.storageRequest("unlock")
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    visible: storageCard.view === "held"
                    icon.name: "object-locked"
                    text: i18n("Try locking again")
                    onClicked: chatView.storageRequest("lock")
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    visible: storageCard.view === "held"
                    icon.name: "dialog-messages"
                    text: i18n("Keep using saved sign-ins")
                    onClicked: chatView.storageRequest("saved-session")
                }
                PlasmaComponents.Button {
                    objectName: "deleteDamagedButton"
                    Layout.fillWidth: true
                    visible: storageCard.view === "damaged" && !chatView.confirmingDelete
                    icon.name: "edit-delete"
                    text: i18n("Delete encrypted folder…")
                    onClicked: chatView.confirmingDelete = true
                }
                Kirigami.InlineMessage {
                    objectName: "deleteDamagedConfirm"
                    Layout.fillWidth: true
                    visible: storageCard.view === "damaged" && chatView.confirmingDelete
                    type: Kirigami.MessageType.Warning
                    text: i18n("Delete the encrypted folder? Every sign-in saved in it is lost, for all Hearthside widgets. This can't be undone.")
                    actions: [
                        Kirigami.Action {
                            text: i18n("Delete")
                            icon.name: "edit-delete"
                            onTriggered: {
                                chatView.confirmingDelete = false
                                chatView.storageRequest("delete-damaged")
                            }
                        },
                        Kirigami.Action {
                            text: i18n("Cancel")
                            icon.name: "dialog-cancel"
                            onTriggered: chatView.confirmingDelete = false
                        }
                    ]
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    visible: storageCard.view === "retry" || storageCard.view === "install"
                    icon.name: "view-refresh"
                    text: storageCard.view === "install" ? i18n("Check again") : i18n("Try again")
                    onClicked: chatView.storageRequest("retry")
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    icon.name: "view-private"
                    text: i18n("Use a private session this time")
                    onClicked: chatView.storageRequest("private")
                }
            }
        }
    }
}
