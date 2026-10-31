import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami
import "ProviderCatalog.js" as Catalog
import "RefreshGate.js" as RefreshGate
import "SnapshotLogic.js" as SnapshotLogic
import "ChatSites.js" as ChatSites

PlasmoidItem {
    id: root

    property var snapshot: ({
        "schema_version": 2,
        "catalog": Catalog.providers,
        "installed_provider_ids": [],
        "providers": []
    })
    property var providerStates: ({})
    property var lastGoodProviders: ({})
    property var cooldownUntil: ({})
    property bool hasData: false
    property string lastError: ""
    property date lastUpdate: new Date(0)
    property bool refreshInFlight: false
    property bool refreshQueued: false
    property double refreshStartedAt: 0
    property string refreshSource: ""
    property int refreshRun: 0

    // Chat tab runtime state; never written to the configuration.
    property string popupTab: "usage"
    property string chatSiteId: ""
    property bool chatPinned: false
    property bool chatDialogOpen: false
    readonly property var chatSites: ChatSites.enabledSites(Plasmoid.configuration.chatSites)
    readonly property var chatSiteIds: root.chatSites.map(function (site) { return site.id })

    readonly property int refreshInterval: normalizedRefresh(
        Plasmoid.configuration.refreshInterval || 300
    )
    readonly property string usageMode:
        Plasmoid.configuration.usageMode === "used" ? "used" : "remaining"
    readonly property var trackedProviders: configuredList(
        Plasmoid.configuration.trackedProviders,
        Catalog.providerIds()
    )
    readonly property var panelProviders: configuredList(
        Plasmoid.configuration.panelProviders,
        ["claude", "codex"]
    )
    readonly property var configuredMetrics: configuredObject(
        Plasmoid.configuration.providerMetrics,
        {"claude": ["weekly"], "codex": ["weekly"]}
    )
    readonly property var compactGroups: compactProviderGroups()
    readonly property color normalUsageColor: {
        var background = Kirigami.Theme.backgroundColor
        var luminance = background.r * 0.2126
            + background.g * 0.7152
            + background.b * 0.0722
        return luminance < 0.5 ? "#32c7d3" : "#008c95"
    }

    function configuredList(value, fallback) {
        try {
            var parsed = JSON.parse(value || "")
            if (Array.isArray(parsed))
                return parsed.filter(function (id) { return Catalog.byId(id) !== null })
        } catch (error) {
        }
        return fallback.slice()
    }

    function configuredObject(value, fallback) {
        try {
            var parsed = JSON.parse(value || "")
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
                return parsed
        } catch (error) {
        }
        return fallback
    }

    function normalizedRefresh(value) {
        var choices = [60, 300, 900, 1800, 3600]
        var closest = choices[0]
        for (var index = 1; index < choices.length; index++) {
            if (Math.abs(choices[index] - value) < Math.abs(closest - value))
                closest = choices[index]
        }
        return closest
    }

    function selectedMetrics(providerId) {
        var configured = root.configuredMetrics[providerId]
        if (!Array.isArray(configured))
            return []
        return configured.filter(function (metricId) {
            return Catalog.metric(providerId, metricId) !== null
        })
    }

    function provider(providerId) {
        return root.providerStates[providerId] || null
    }

    // Thin wrappers: reading root.usageMode here keeps callers' bindings live.
    function windowFor(providerData, metricId) {
        return SnapshotLogic.windowFor(providerData, metricId)
    }

    function metricReading(providerData, metricId) {
        return SnapshotLogic.metricReading(providerData, metricId, root.usageMode)
    }

    function displayedPercent(rawUsed) {
        return SnapshotLogic.displayedPercent(rawUsed, root.usageMode)
    }

    function formatReading(reading) {
        if (!reading)
            return "—"
        if (reading.type === "percentage")
            return Math.round(reading.value) + "%"
        if (reading.type === "money")
            return "$" + Number(reading.value).toFixed(2)
        if (reading.type === "credits")
            return String(Math.round(reading.value))
        return "—"
    }

    function barColor(rawUsed) {
        if (rawUsed >= 85)
            return Kirigami.Theme.negativeTextColor
        if (rawUsed >= 60)
            return Kirigami.Theme.neutralTextColor
        return root.normalUsageColor
    }

    function valueColor(rawUsed) {
        if (rawUsed >= 85)
            return Kirigami.Theme.negativeTextColor
        if (rawUsed >= 60)
            return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.textColor
    }

    function providerIconSource(providerId) {
        var descriptor = Catalog.byId(providerId)
        return descriptor
            ? Qt.resolvedUrl("../images/" + descriptor.icon)
            : "speedometer"
    }

    function compactProviderGroups() {
        var result = []
        var installed = root.snapshot.installed_provider_ids || []
        for (var index = 0; index < root.panelProviders.length; index++) {
            var providerId = root.panelProviders[index]
            if (installed.indexOf(providerId) < 0)
                continue
            var metrics = root.selectedMetrics(providerId)
            if (metrics.length === 0)
                continue
            result.push({
                provider_id: providerId,
                descriptor: Catalog.byId(providerId),
                provider: root.provider(providerId),
                metrics: metrics
            })
        }
        return result
    }

    function activeProviderIds() {
        var now = Date.now()
        var installed = root.snapshot.installed_provider_ids || []
        var knownInstallations = root.hasData
        var result = []
        for (var index = 0; index < root.trackedProviders.length; index++) {
            var providerId = root.trackedProviders[index]
            if (knownInstallations && installed.indexOf(providerId) < 0)
                continue
            var retry = Number(root.cooldownUntil[providerId] || 0)
            if (retry > now)
                continue
            result.push(providerId)
        }
        return result
    }

    function refresh() {
        var providerIds = activeProviderIds()
        if (root.hasData && providerIds.length === 0)
            return
        // Only one helper may run at a time; extra requests collapse into a
        // single follow-up run once the current one reports back.
        var now = Date.now()
        if (RefreshGate.decide(root.refreshInFlight, root.refreshStartedAt, now) === "queue") {
            root.refreshQueued = true
            return
        }
        // Drop a stale run; each run gets a unique command so its late reply
        // can never be mistaken for the current run.
        if (root.refreshSource !== "")
            usageSource.disconnectSource(root.refreshSource)
        root.refreshRun += 1
        var command = RefreshGate.usageCommand(root.refreshRun, providerIds)
        root.refreshInFlight = true
        root.refreshQueued = false
        root.refreshStartedAt = now
        root.refreshSource = command
        usageSource.connectSource(command)
    }

    function applySnapshot(payload) {
        if (!payload || payload.schema_version !== 2)
            throw new Error("Unsupported helper schema")
        var merged = SnapshotLogic.mergeResults(
            root.providerStates,
            root.lastGoodProviders,
            root.cooldownUntil,
            payload.providers || []
        )
        var states = merged.states

        var installed = payload.installed_provider_ids || []
        var visible = []
        var catalog = payload.catalog && payload.catalog.length
            ? payload.catalog : Catalog.providers
        for (var catalogIndex = 0; catalogIndex < catalog.length; catalogIndex++) {
            var descriptor = catalog[catalogIndex]
            if (installed.indexOf(descriptor.provider_id) >= 0
                    && root.trackedProviders.indexOf(descriptor.provider_id) >= 0
                    && states[descriptor.provider_id]) {
                visible.push(states[descriptor.provider_id])
            }
        }
        root.providerStates = states
        root.lastGoodProviders = merged.goods
        root.cooldownUntil = merged.cooldowns
        root.snapshot = {
            schema_version: 2,
            generated_at: payload.generated_at,
            catalog: catalog,
            installed_provider_ids: installed,
            providers: visible
        }
        root.hasData = true
        root.lastError = ""
        root.lastUpdate = new Date()
    }

    function rebuildVisibleProviders() {
        if (!root.hasData)
            return
        var installed = root.snapshot.installed_provider_ids || []
        var catalog = root.snapshot.catalog || Catalog.providers
        var visible = []
        for (var index = 0; index < catalog.length; index++) {
            var providerId = catalog[index].provider_id
            if (installed.indexOf(providerId) >= 0
                    && root.trackedProviders.indexOf(providerId) >= 0
                    && root.providerStates[providerId]) {
                visible.push(root.providerStates[providerId])
            }
        }
        root.snapshot = Object.assign({}, root.snapshot, {providers: visible})
    }

    function syncChatSite() {
        if (root.chatSiteIds.indexOf(root.chatSiteId) < 0)
            root.chatSiteId = ChatSites.initialSite(
                root.chatSiteIds,
                Plasmoid.configuration.chatDefaultSite
            )
        if (root.chatSiteIds.length === 0)
            root.popupTab = "usage"
    }

    function setUsageMode(mode) {
        Plasmoid.configuration.usageMode = mode === "used" ? "used" : "remaining"
    }

    Plasma5Support.DataSource {
        id: usageSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            usageSource.disconnectSource(source)
            if (source === root.refreshSource) {
                root.refreshInFlight = false
                root.refreshSource = ""
            }
            var code = data["exit code"]
            var output = (data["stdout"] || "").toString()
            if (code === 0 && output.trim().length > 0) {
                try {
                    root.applySnapshot(JSON.parse(output))
                } catch (error) {
                    root.lastError = i18n("Could not parse helper output")
                }
            } else {
                var errorText = (data["stderr"] || "").toString().trim()
                root.lastError = errorText.length > 0
                    ? errorText.split("\n").pop()
                    : i18n("Helper exited with code %1", code)
            }
            if (!root.refreshInFlight && root.refreshQueued) {
                root.refreshQueued = false
                Qt.callLater(root.refresh)
            }
        }
    }

    Timer {
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: firstRunSettingsTimer
        interval: 1200
        repeat: false
        onTriggered: Plasmoid.internalAction("configure").trigger()
    }

    Component.onCompleted: {
        if (Plasmoid.configuration.refreshInterval !== root.refreshInterval)
            Plasmoid.configuration.refreshInterval = root.refreshInterval
        if (Plasmoid.configuration.configSchemaVersion !== 2)
            Plasmoid.configuration.configSchemaVersion = 2
        if (!Plasmoid.configuration.initialSetupComplete) {
            Plasmoid.configuration.initialSetupComplete = true
            firstRunSettingsTimer.start()
        }
        root.syncChatSite()
    }

    onTrackedProvidersChanged: {
        root.rebuildVisibleProviders()
        root.refresh()
    }
    onExpandedChanged: {
        if (root.expanded)
            root.refresh()
        else
            root.chatPinned = false
    }
    onChatSiteIdsChanged: root.syncChatSite()

    hideOnWindowDeactivate: !root.chatPinned && !root.chatDialogOpen

    Plasmoid.icon: Qt.resolvedUrl("../images/hearthside.svg")
    Plasmoid.busy: !root.hasData && root.lastError === ""
    toolTipMainText: i18n("Hearthside")
    toolTipSubText: {
        if (root.lastError !== "" && !root.hasData)
            return i18n("Error: %1", root.lastError)
        if (!root.hasData)
            return i18n("Loading…")
        if (root.compactGroups.length === 0)
            return i18n("No panel metrics selected.")
        var lines = []
        for (var groupIndex = 0; groupIndex < root.compactGroups.length; groupIndex++) {
            var group = root.compactGroups[groupIndex]
            var values = []
            for (var metricIndex = 0; metricIndex < group.metrics.length; metricIndex++) {
                var metricId = group.metrics[metricIndex]
                var metric = Catalog.metric(group.provider_id, metricId)
                values.push(metric.title + " "
                    + root.formatReading(root.metricReading(group.provider, metricId)))
            }
            lines.push(group.descriptor.display_name + ": " + values.join(" · "))
        }
        return lines.join("\n")
    }

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh now")
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        }
    ]
}
