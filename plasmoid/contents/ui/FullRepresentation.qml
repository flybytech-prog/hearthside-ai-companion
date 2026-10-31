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

    readonly property bool chatAvailable: root.chatSiteIds.length > 0
    readonly property bool onChat: full.chatAvailable && root.popupTab === "chat"
    readonly property var popupSize: ChatSites.popupSize(
        full.onChat ? "chat" : "usage",
        Kirigami.Units.gridUnit,
        // The popup's own screen, not the whole virtual desktop.
        Screen.width,
        Screen.height
    )

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 15
    Layout.preferredWidth: full.popupSize.width
    Layout.preferredHeight: full.popupSize.height

    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded && full.onChat)
                chatView.focusLater()
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
                    visible: !full.chatAvailable
                    level: 2
                    text: i18n("Hearthside")
                    elide: Text.ElideRight
                }
                PlasmaComponents.TabBar {
                    id: tabBar
                    Layout.fillWidth: true
                    visible: full.chatAvailable

                    Binding on currentIndex {
                        value: full.onChat ? 1 : 0
                    }

                    PlasmaComponents.TabButton {
                        text: i18n("Usage")
                        icon.name: "speedometer"
                        onClicked: root.popupTab = "usage"
                    }
                    PlasmaComponents.TabButton {
                        text: i18n("Chat")
                        icon.name: "dialog-messages"
                        onClicked: root.popupTab = "chat"
                    }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
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
                                text: siteDelegate.modelData.name
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "go-previous"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: chatView.canGoBack
                    onClicked: chatView.goBack()
                    QQC2.ToolTip.text: i18n("Back")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: chatView.available
                    onClicked: chatView.reload()
                    QQC2.ToolTip.text: i18n("Reload page")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "go-home"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: chatView.available
                    onClicked: chatView.home()
                    QQC2.ToolTip.text: i18n("Home")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: chatView.canOpenExternally
                    onClicked: chatView.openExternally()
                    QQC2.ToolTip.text: i18n("Open in browser")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "window-pin"
                    display: QQC2.AbstractButton.IconOnly
                    checkable: true
                    checked: root.chatPinned
                    onToggled: root.chatPinned = checked
                    QQC2.ToolTip.text: i18n("Keep open")
                    QQC2.ToolTip.visible: hovered
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-clear-history"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: chatView.available
                    onClicked: chatView.confirmingClear = true
                    QQC2.ToolTip.text: i18n("Clear chat data")
                    QQC2.ToolTip.visible: hovered
                }
            }
        }
    }

    contentItem: StackLayout {
        currentIndex: full.onChat ? 1 : 0

        UsageView {}

        ChatView {
            id: chatView
            siteIds: root.chatSiteIds
            siteId: root.chatSiteId
            current: full.onChat
        }
    }

    Binding {
        target: root
        property: "chatDialogOpen"
        value: chatView.dialogOpen
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
                text: root.hasData
                    ? i18n("Updated %1", Qt.formatTime(root.lastUpdate, "HH:mm:ss"))
                    : i18n("Loading…")
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
            }
            PlasmaComponents.Label {
                text: root.usageMode === "used" ? i18n("Used") : i18n("Left")
                opacity: 0.6
                font: Kirigami.Theme.smallFont
            }
        }
    }
}
