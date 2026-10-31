import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import "ChatSites.js" as ChatSites

KCM.SimpleKCM {
    id: page

    // Every key is declared so the config dialog can map all of them.
    property string cfg_trackedProviders:
        "[\"claude\",\"codex\",\"cursor\",\"antigravity\",\"copilot\",\"devin\",\"grok\"]"
    property string cfg_trackedProvidersDefault:
        "[\"claude\",\"codex\",\"cursor\",\"antigravity\",\"copilot\",\"devin\",\"grok\"]"
    property string cfg_panelProviders: "[\"claude\",\"codex\"]"
    property string cfg_panelProvidersDefault: "[\"claude\",\"codex\"]"
    property string cfg_providerMetrics:
        "{\"claude\":[\"weekly\"],\"codex\":[\"weekly\"]}"
    property string cfg_providerMetricsDefault:
        "{\"claude\":[\"weekly\"],\"codex\":[\"weekly\"]}"
    property string cfg_usageMode: "remaining"
    property string cfg_usageModeDefault: "remaining"
    property int cfg_refreshInterval: 300
    property int cfg_refreshIntervalDefault: 300
    property int cfg_configSchemaVersion: 2
    property int cfg_configSchemaVersionDefault: 2
    property bool cfg_initialSetupComplete: false
    property bool cfg_initialSetupCompleteDefault: false
    property string cfg_chatSites:
        "[\"claude\",\"chatgpt\",\"grok\",\"gemini\",\"copilot\",\"mscopilot\"]"
    property string cfg_chatSitesDefault:
        "[\"claude\",\"chatgpt\",\"grok\",\"gemini\",\"copilot\",\"mscopilot\"]"
    property string cfg_chatDefaultSite: "claude"
    property string cfg_chatDefaultSiteDefault: "claude"

    readonly property var enabledSites: ChatSites.enabledSites(page.cfg_chatSites)
    readonly property var enabledIds: page.enabledSites.map(function (site) { return site.id })

    function setEnabled(siteId, enabled) {
        var ids = ChatSites.siteIds().filter(function (id) {
            return id === siteId ? enabled : page.enabledIds.indexOf(id) >= 0
        })
        page.cfg_chatSites = JSON.stringify(ids)
        if (ids.indexOf(page.cfg_chatDefaultSite) < 0 && ids.length > 0)
            page.cfg_chatDefaultSite = ids[0]
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            level: 2
            text: i18n("Chat sites")
        }

        Repeater {
            model: ChatSites.sites

            delegate: RowLayout {
                id: siteRow
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.CheckBox {
                    id: siteCheck
                    checked: page.enabledIds.indexOf(siteRow.modelData.id) >= 0
                    onToggled: page.setEnabled(siteRow.modelData.id, checked)
                }
                Kirigami.Icon {
                    source: Qt.resolvedUrl("../images/" + siteRow.modelData.icon)
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    isMask: true
                    color: Kirigami.Theme.textColor
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    text: siteRow.modelData.name
                    elide: Text.ElideRight
                    MouseArea {
                        anchors.fill: parent
                        onClicked: page.setEnabled(siteRow.modelData.id, !siteCheck.checked)
                    }
                }
            }
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.ComboBox {
                Kirigami.FormData.label: i18n("Open first:")
                enabled: page.enabledSites.length > 0
                model: page.enabledSites
                textRole: "name"
                valueRole: "id"
                currentIndex: Math.max(0, page.enabledIds.indexOf(
                    ChatSites.initialSite(page.enabledIds, page.cfg_chatDefaultSite)
                ))
                onActivated: page.cfg_chatDefaultSite = currentValue
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: page.enabledSites.length === 0
            text: i18n("The Chat tab is hidden while no site is enabled.")
            wrapMode: Text.WordWrap
            opacity: 0.72
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        Kirigami.Heading {
            level: 2
            text: i18n("Privacy")
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: i18n(
                "Chat sites open in a private, in-memory browser profile. You are signed out on every Plasma restart; nothing is saved to disk. Clear chat data signs you out immediately."
            )
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.72
            text: i18n(
                "The widget never reads or changes the pages and sends nothing to the developer. Microphone, camera, screen sharing, notifications, location and clipboard reading are always denied. Downloads ask first and go to your Downloads folder. Links to other websites open in your browser."
            )
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.72
            text: i18n(
                "Text you copy may be kept by your clipboard manager if it saves history. Each open site uses roughly 200–500 MB of memory."
            )
        }
    }
}
