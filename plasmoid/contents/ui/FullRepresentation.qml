import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Window
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "ChatSites.js" as ChatSites

PlasmaExtras.Representation {
    id: full

    // Settings → General → Show tabs; Chat also needs an enabled site.
    readonly property bool chatAvailable: root.chatShown
    readonly property bool onChat: full.chatAvailable && root.shownTab === "chat"
    // The built-in Ollama chat is shown instead of the web chat.
    readonly property bool onOllama: full.onChat && root.chatSiteId === "ollama"
    readonly property var popupSize: ChatSites.popupSize(
        full.onChat ? "chat" : "usage",
        Kirigami.Units.gridUnit,
        // The popup's own screen, not the whole virtual desktop.
        Screen.width,
        Screen.height,
        root.popupScale
    )

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 15
    Layout.preferredWidth: full.popupSize.width
    Layout.preferredHeight: full.popupSize.height

    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded && full.onOllama)
                ollamaView.focusLater()
            else if (root.expanded && full.onChat)
                chatView.focusLater()
        }
        // A hidden Chat tab keeps no web view or saved sign-ins open.
        function onChatShownChanged() {
            if (!root.chatShown)
                chatView.stop()
        }
    }

    header: PlasmaExtras.PlasmoidHeading {
        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true

                Kirigami.Heading {
                    Layout.fillWidth: true
                    visible: !tabBar.visible
                    level: 2
                    text: i18n("Hearthside")
                    elide: Text.ElideRight
                }
                PlasmaComponents.TabBar {
                    id: tabBar
                    Layout.fillWidth: true
                    visible: full.chatAvailable && root.usageShown

                    Binding on currentIndex {
                        value: full.onChat ? 0 : 1
                    }

                    PlasmaComponents.TabButton {
                        text: i18n("Chat")
                        icon.name: "dialog-messages"
                        onClicked: root.popupTab = "chat"
                    }
                    PlasmaComponents.TabButton {
                        text: i18n("Usage")
                        icon.name: "speedometer"
                        onClicked: root.popupTab = "usage"
                    }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    visible: root.usageShown
                    onClicked: root.refresh()
                    QQC2.ToolTip.text: i18n("Refresh now")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: Plasmoid.internalAction("configure").trigger()
                    QQC2.ToolTip.text: i18n("Configure…")
                    QQC2.ToolTip.visible: hovered
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: !full.onChat

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: i18n("Show")
                    opacity: 0.65
                }
                QQC2.Button {
                    text: i18n("Left")
                    checkable: true
                    checked: root.usageMode === "remaining"
                    onClicked: root.setUsageMode("remaining")
                }
                QQC2.Button {
                    text: i18n("Used")
                    checkable: true
                    checked: root.usageMode === "used"
                    onClicked: root.setUsageMode("used")
                }
                // Hides the popup; chat pages and conversations stay as they are.
                PlasmaComponents.ToolButton {
                    icon.name: "window-minimize"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: root.expanded = false
                    QQC2.ToolTip.text: i18n("Minimize")
                    QQC2.ToolTip.visible: hovered
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: full.onChat
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.ComboBox {
                    id: siteCombo
                    Layout.fillWidth: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 5
                    model: root.chatSites
                    textRole: "name"
                    valueRole: "id"
                    currentIndex: root.chatSiteIds.indexOf(root.chatSiteId)
                    onActivated: root.chatSiteId = currentValue

                    delegate: PlasmaComponents.ItemDelegate {
                        id: siteDelegate
                        required property var modelData
                        required property int index
                        width: ListView.view ? ListView.view.width : implicitWidth
                        highlighted: siteCombo.highlightedIndex === siteDelegate.index
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: Qt.resolvedUrl("../images/" + siteDelegate.modelData.icon)
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                isMask: true
                                color: Kirigami.Theme.textColor
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: siteDelegate.modelData.name
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
                PlasmaComponents.ComboBox {
                    id: modelCombo
                    Layout.fillWidth: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 5
                    visible: full.onOllama
                    enabled: ollamaView.modelList.length > 0
                    model: ollamaView.modelList
                    textRole: "name"
                    valueRole: "name"
                    currentIndex: ollamaView.modelIndex
                    displayText: ollamaView.modelIndex >= 0 ? currentText : i18n("No model")
                    onActivated: ollamaView.selectModel(currentValue)
                    Accessible.name: i18n("Model")

                    // Model names come from the server: plain text only.
                    delegate: PlasmaComponents.ItemDelegate {
                        id: modelDelegate
                        required property var modelData
                        required property int index
                        width: ListView.view ? ListView.view.width : implicitWidth
                        highlighted: modelCombo.highlightedIndex === modelDelegate.index
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: modelDelegate.modelData.name
                                elide: Text.ElideRight
                            }
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                visible: text !== ""
                                text: modelDelegate.modelData.parameterSize
                                opacity: 0.6
                            }
                        }
                    }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    visible: full.onOllama
                    enabled: !ollamaView.busy
                    onClicked: ollamaView.reloadModels()
                    QQC2.ToolTip.text: i18n("Reload models")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "go-previous"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama
                    enabled: chatView.canGoBack
                    onClicked: chatView.goBack()
                    QQC2.ToolTip.text: i18n("Back")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama
                    enabled: chatView.available
                    onClicked: chatView.reload()
                    QQC2.ToolTip.text: i18n("Reload page")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "go-home"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama
                    enabled: chatView.available
                    onClicked: chatView.home()
                    QQC2.ToolTip.text: i18n("Home")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama
                    enabled: chatView.canOpenExternally
                    onClicked: chatView.openExternally()
                    QQC2.ToolTip.text: i18n("Open in browser")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "window-minimize"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: root.expanded = false
                    QQC2.ToolTip.text: i18n("Minimize")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "object-locked"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama && chatView.persistentActive
                    onClicked: chatView.lockSaved()
                    QQC2.ToolTip.text: i18n("Lock saved sign-ins")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-clear-history"
                    display: QQC2.AbstractButton.IconOnly
                    visible: !full.onOllama
                    enabled: chatView.available
                    onClicked: chatView.confirmingClear = true
                    QQC2.ToolTip.text: i18n("Clear chat data")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-clear-history"
                    display: QQC2.AbstractButton.IconOnly
                    visible: full.onOllama
                    enabled: ollamaView.hasConversation
                    onClicked: ollamaView.confirmingClear = true
                    QQC2.ToolTip.text: i18n("Clear conversation")
                    QQC2.ToolTip.visible: hovered
                }
            }
        }
    }

    contentItem: StackLayout {
        currentIndex: full.onChat ? 0 : 1

        StackLayout {
            currentIndex: root.chatSiteId === "ollama" ? 1 : 0

            ChatView {
                id: chatView
                siteIds: root.chatWebSiteIds
                siteId: root.chatWebSiteId
                customUrls: root.chatCustomUrls
                appletId: Math.max(0, root.chatAppletId)
                // Only while the popup is open and a web site is shown, so no
                // web engine starts early or for Ollama alone.
                current: full.onChat && root.expanded && root.chatSiteId !== "ollama"
                storageMode: root.chatStorageMode
                storageReady: root.chatStorageReady
                storagePath: root.chatProfilePath
                profileName: root.chatProfileName
                card: root.chatCard
                missingTools: root.chatVaultMissing
                storageNotice: root.chatStorageNotice
                autoLockMinutes: root.chatAutoLockMinutes
                storageBusy: root.chatStorageBusy || root.chatDialogOpen
                onStorageRequest: (action) => root.chatStorageRequest(action)
            }

            OllamaChatView {
                id: ollamaView
                current: full.onOllama && root.expanded
                siteEnabled: root.chatShown && root.chatSiteIds.indexOf("ollama") >= 0
                address: root.chatOllamaAddress
                appletId: Math.max(0, root.chatAppletId)
            }
        }

        UsageView {}
    }

    Binding {
        target: root
        property: "chatDialogOpen"
        // Also while a helper passphrase window is open, so the popup stays.
        value: chatView.dialogOpen || root.chatVaultPrompting
    }

    footer: Item {
        visible: !full.onChat
        implicitHeight: footerRow.implicitHeight + Kirigami.Units.smallSpacing * 2

        Kirigami.Separator {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
        }
        RowLayout {
            id: footerRow
            anchors {
                fill: parent
                leftMargin: Kirigami.Units.largeSpacing
                rightMargin: Kirigami.Units.largeSpacing
                topMargin: Kirigami.Units.smallSpacing
                bottomMargin: Kirigami.Units.smallSpacing
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.hasData
                    ? i18n("Updated %1", Qt.formatTime(root.lastUpdate, "HH:mm:ss"))
                    : i18n("Loading…")
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
            }
            PlasmaComponents.Label {
                textFormat: Text.PlainText
                text: root.usageMode === "used" ? i18n("Used") : i18n("Left")
                opacity: 0.6
                font: Kirigami.Theme.smallFont
            }
        }
    }
}
