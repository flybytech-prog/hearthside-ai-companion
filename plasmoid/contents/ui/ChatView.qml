import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

// Chat tab body. Qt WebEngine is only reached through the Loader below, so
// the widget keeps working (with a hint) when the module is missing, and no
// web engine starts until the Chat tab is first opened.
ColumnLayout {
    id: chatView

    property var siteIds: []
    property string siteId: ""
    // Validated {siteId: url} custom addresses; runtime only.
    property var customUrls: ({})
    // True while the Chat tab is the visible one.
    property bool current: false

    property bool started: false
    property bool clearing: false
    property bool confirmingClear: false

    readonly property var web: webLoader.status === Loader.Ready ? webLoader.item : null
    readonly property bool available: chatView.web !== null
    readonly property bool dialogOpen: !!chatView.web && chatView.web.dialogOpen
    readonly property bool canGoBack: !!chatView.web && chatView.web.canGoBack
    readonly property bool canOpenExternally: !!chatView.web && chatView.web.canOpenExternally
    readonly property bool localSite: chatView.siteId === "local"

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
    function clearChatData() {
        chatView.confirmingClear = false
        if (chatView.web) {
            chatView.web.cancelDownload()
            chatView.web.closeOverlay()
        }
        chatView.clearing = true
        gc()
        Qt.callLater(chatView.finishClear)
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

    onCurrentChanged: {
        if (chatView.current) {
            chatView.started = true
            chatView.focusLater()
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
        text: i18n("Clear chat data? This signs you out of all chat sites.")
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

        Loader {
            id: webLoader
            anchors.fill: parent
            active: chatView.started && !chatView.clearing
            source: "ChatWebView.qml"
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
            visible: webLoader.status === Loader.Error
            iconName: "dialog-messages"
            text: i18n("Chat needs Qt WebEngine 6.8 or newer and Qt Quick Dialogs (packages qt6-webengine, qt6-declarative)")
        }
    }
}
