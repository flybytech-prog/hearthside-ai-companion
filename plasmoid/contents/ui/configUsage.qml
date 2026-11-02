import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support
import "ProviderCatalog.js" as Catalog

KCM.ScrollViewKCM {
    id: page

    property string cfg_trackedProviders:
        "[\"claude\",\"codex\",\"cursor\",\"antigravity\",\"copilot\",\"devin\",\"grok\"]"
    property string cfg_trackedProvidersDefault:
        "[\"claude\",\"codex\",\"cursor\",\"antigravity\",\"copilot\",\"devin\",\"grok\"]"
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
    property string cfg_chatCustomUrls: "{}"
    property string cfg_chatCustomUrlsDefault: "{}"
    property string cfg_chatSignInStorage: "memory"
    property string cfg_chatSignInStorageDefault: "memory"
    // Written only by main.qml; kept in step so Apply never writes back an
    // old value.
    property int cfg_chatProfileGeneration: 0
    property int cfg_chatProfileGenerationDefault: 0
    property int cfg_chatAutoLockMinutes: 0
    property int cfg_chatAutoLockMinutesDefault: 0
    property bool cfg_chatKeepOpen: false
    property bool cfg_chatKeepOpenDefault: false
    property string cfg_chatOllamaUrl: "http://127.0.0.1:11434"
    property string cfg_chatOllamaUrlDefault: "http://127.0.0.1:11434"
    property string cfg_popupDefaultTab: "chat"
    property string cfg_popupDefaultTabDefault: "chat"
    property bool cfg_showUsageTab: true
    property bool cfg_showUsageTabDefault: true
    property bool cfg_showChatTab: true
    property bool cfg_showChatTabDefault: true
    property string cfg_popupSize: "normal"
    property string cfg_popupSizeDefault: "normal"
    property bool cfg_tooltipShowsUsage: true
    property bool cfg_tooltipShowsUsageDefault: true

    property var catalogModel: Catalog.providers
    property var installedProviderIds: []
    property var providerResults: ({})
    property string statusMessage: ""
    property bool checkingProviders: false
    property bool detecting: false
    readonly property string detectCommand: "python3 -P -m hearthside --detect"

    function parseList(value, fallback) {
        try {
            var parsed = JSON.parse(value || "")
            if (Array.isArray(parsed))
                return parsed
        } catch (error) {
        }
        return fallback.slice()
    }

    function parseMetrics() {
        try {
            var parsed = JSON.parse(page.cfg_providerMetrics || "")
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
                return parsed
        } catch (error) {
        }
        return {}
    }

    function tracked() {
        return parseList(page.cfg_trackedProviders, Catalog.providerIds())
    }

    function contains(list, value) {
        return list.indexOf(value) >= 0
    }

    function setMembership(list, value, enabled) {
        var result = list.slice()
        var index = result.indexOf(value)
        if (enabled && index < 0)
            result.push(value)
        else if (!enabled && index >= 0)
            result.splice(index, 1)
        return result
    }

    function setTracked(providerId, enabled) {
        page.cfg_trackedProviders = JSON.stringify(
            setMembership(tracked(), providerId, enabled)
        )
    }

    function selectedMetrics(providerId) {
        var result = parseMetrics()[providerId]
        return Array.isArray(result) ? result : []
    }

    function setMetric(providerId, metricId, enabled) {
        var metrics = parseMetrics()
        var selected = Array.isArray(metrics[providerId])
            ? metrics[providerId].slice() : []
        selected = setMembership(selected, metricId, enabled)
        metrics[providerId] = selected
        page.cfg_providerMetrics = JSON.stringify(metrics)
        if (enabled) {
            page.cfg_trackedProviders = JSON.stringify(
                setMembership(tracked(), providerId, true)
            )
        }
    }

    function resultFor(providerId) {
        return page.providerResults[providerId] || null
    }

    function providerStatus(providerId) {
        if (!contains(page.installedProviderIds, providerId)) {
            return page.detecting && page.installedProviderIds.length === 0
                ? i18n("Checking…") : i18n("Not detected")
        }
        var result = resultFor(providerId)
        if (!result)
            return page.checkingProviders ? i18n("Checking…") : i18n("Detected")
        if (result.status === "ok")
            return result.plan ? i18n("Connected · %1", result.plan) : i18n("Connected")
        if (result.status === "stale")
            return i18n("Connected · stale")
        return result.error_message || result.status
    }

    function metricAvailable(providerId, metricId) {
        var result = resultFor(providerId)
        return !result || !Array.isArray(result.available_metrics)
            || contains(result.available_metrics, metricId)
    }

    function refreshProviders() {
        page.checkingProviders = true
        var safe = tracked().filter(function (providerId) {
            return Catalog.byId(providerId) !== null
        })
        providerSource.connectSource(
            "python3 -P -m hearthside --json --providers=" + safe.join(",")
        )
    }

    // Network-free: only reports which providers are installed.
    function detectProviders() {
        page.detecting = true
        providerSource.connectSource(page.detectCommand)
    }

    Component.onCompleted: {
        page.cfg_configSchemaVersion = 2
        page.cfg_initialSetupComplete = true
        Qt.callLater(page.detectProviders)
    }

    Connections {
        target: Plasmoid.configuration
        function onValueChanged(key, value) {
            if (key === "chatProfileGeneration")
                page.cfg_chatProfileGeneration = value
        }
    }

    Plasma5Support.DataSource {
        id: providerSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            providerSource.disconnectSource(source)
            var detectOnly = source === page.detectCommand
            if (detectOnly)
                page.detecting = false
            else
                page.checkingProviders = false
            try {
                var payload = JSON.parse((data["stdout"] || "").toString())
                if (payload.schema_version !== 2)
                    throw new Error("schema")
                if (payload.catalog && payload.catalog.length)
                    page.catalogModel = payload.catalog
                page.statusMessage = ""
                page.installedProviderIds = payload.installed_provider_ids || []
                // Detection carries no status; keep results from a network run.
                if (detectOnly)
                    return
                var results = {}
                var providers = payload.providers || []
                for (var index = 0; index < providers.length; index++)
                    results[providers[index].provider_id] = providers[index]
                page.providerResults = results
            } catch (error) {
                page.statusMessage = i18n("Could not read provider status.")
            }
        }
    }

    view: ListView {
        id: providerList
        clip: true
        spacing: Kirigami.Units.smallSpacing
        model: page.catalogModel

        header: ColumnLayout {
            width: providerList.width
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    level: 2
                    text: i18n("Providers")
                }
                Kirigami.ContextualHelpButton {
                    toolTipText: i18n("Tracked providers appear in the Usage tab. The checked metrics are shown when you hover over the panel icon. Credentials stay on this computer; the helper only contacts the usage APIs of providers you track.")
                }
                Item {
                    Layout.fillWidth: true
                }
                QQC2.Button {
                    text: page.checkingProviders ? i18n("Checking…") : i18n("Refresh status")
                    icon.name: "view-refresh"
                    enabled: !page.checkingProviders
                    onClicked: page.refreshProviders()
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                visible: !page.cfg_showUsageTab
                text: i18n("The Usage tab is hidden in General, so usage isn't refreshed.")
                wrapMode: Text.WordWrap
                opacity: 0.72
            }
        }

        delegate: Rectangle {
            id: providerRow
            required property var modelData
            width: providerList.width
            implicitHeight: providerColumn.implicitHeight
                + Kirigami.Units.largeSpacing * 2
            radius: Kirigami.Units.smallSpacing
            color: Qt.rgba(
                Kirigami.Theme.textColor.r,
                Kirigami.Theme.textColor.g,
                Kirigami.Theme.textColor.b,
                0.045
            )

            ColumnLayout {
                id: providerColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: Kirigami.Units.largeSpacing
                }
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true

                    Kirigami.Icon {
                        source: Qt.resolvedUrl(
                            "../images/" + providerRow.modelData.icon
                        )
                        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                        isMask: true
                        color: Kirigami.Theme.textColor
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Kirigami.Heading {
                            Layout.fillWidth: true
                            level: 4
                            textFormat: Text.PlainText
                            text: providerRow.modelData.display_name
                            elide: Text.ElideRight
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            // Helper text: never rich text.
                            textFormat: Text.PlainText
                            text: page.providerStatus(
                                providerRow.modelData.provider_id
                            )
                            opacity: 0.62
                            elide: Text.ElideRight
                            font: Kirigami.Theme.smallFont
                        }
                    }
                    QQC2.Switch {
                        text: i18n("Track")
                        checked: page.contains(
                            page.tracked(),
                            providerRow.modelData.provider_id
                        )
                        onClicked: page.setTracked(
                            providerRow.modelData.provider_id,
                            checked
                        )
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: providerRow.modelData.metrics || []

                        delegate: QQC2.CheckBox {
                            id: metricCheck
                            required property var modelData
                            text: page.metricAvailable(
                                providerRow.modelData.provider_id,
                                metricCheck.modelData.id
                            )
                                ? metricCheck.modelData.title
                                : i18n("%1 (unavailable)", metricCheck.modelData.title)
                            opacity: page.metricAvailable(
                                providerRow.modelData.provider_id,
                                metricCheck.modelData.id
                            ) ? 1 : 0.65
                            checked: page.contains(
                                page.selectedMetrics(
                                    providerRow.modelData.provider_id
                                ),
                                metricCheck.modelData.id
                            )
                            onClicked: page.setMetric(
                                providerRow.modelData.provider_id,
                                metricCheck.modelData.id,
                                checked
                            )
                        }
                    }
                }
            }
        }

        footer: ColumnLayout {
            width: providerList.width
            spacing: Kirigami.Units.largeSpacing

            QQC2.Label {
                visible: page.statusMessage !== ""
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: page.statusMessage
                wrapMode: Text.WordWrap
                opacity: 0.72
            }
            Item {
                implicitHeight: Kirigami.Units.largeSpacing
            }
        }
    }
}
