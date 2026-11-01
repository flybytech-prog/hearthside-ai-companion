import QtCore
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
import "ChatStorage.js" as ChatStorage
import "OllamaChat.js" as OllamaChat

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
    property string popupTab: "chat"
    property string chatSiteId: ""
    property bool chatPinned: false
    property bool chatDialogOpen: false
    // Web sites, then the built-in Ollama chat when it is on.
    readonly property var chatSites: OllamaChat.menuEntries(
        ChatSites.enabledSites(Plasmoid.configuration.chatSites),
        Plasmoid.configuration.chatSites)
    readonly property var chatSiteIds: root.chatSites.map(function (site) { return site.id })
    // The web chat only knows web sites. It keeps its last one while Ollama
    // is shown, so its pages stay as they were.
    readonly property var chatWebSiteIds: root.chatSiteIds.filter(function (id) {
        return id !== OllamaChat.ENTRY.id
    })
    property string chatWebSiteId: ""
    // Validated loopback address; anything odd → the default.
    readonly property string chatOllamaAddress:
        OllamaChat.effectiveAddress(Plasmoid.configuration.chatOllamaUrl)
    // {siteId: url}; only valid addresses survive, anything odd → built-in.
    readonly property var chatCustomUrls:
        ChatSites.parseCustomUrls(Plasmoid.configuration.chatCustomUrls)

    // Stay signed in. Runtime state only; nothing here reaches the config
    // except chatProfileGeneration. The helper reports short codes and the
    // profile path is derived here, never received or shown.
    readonly property string chatStorageMode:
        ChatStorage.normalizeMode(Plasmoid.configuration.chatSignInStorage)
    readonly property int chatConfiguredGeneration:
        ChatStorage.normalizeGeneration(Plasmoid.configuration.chatProfileGeneration)
    // -1 until Component.onCompleted has read the configuration.
    property int chatGeneration: -1
    property string chatModeSeen: "memory"
    readonly property int chatAppletId: ChatStorage.validInt(Plasmoid.id)
    readonly property string chatProfileName:
        ChatStorage.profileName(root.chatAppletId, root.chatGeneration)
    // Same rule as the helper: $XDG_RUNTIME_DIR, else nothing (memory only).
    readonly property string chatProfilePath: ChatStorage.profilePath(
        StandardPaths.writableLocation(StandardPaths.RuntimeLocation),
        root.chatAppletId, root.chatGeneration)
    // "", absent, locked, unlocked, unavailable, error
    property string chatVaultState: ""
    property var chatVaultMissing: []
    // Generation the helper prepared inside the verified mount; -1 = none.
    property int chatPreparedGeneration: -1
    // The user locked or cleared: don't reopen saved sign-ins by itself.
    property bool chatVaultHold: false
    property bool chatPrivateSession: false
    property string chatVaultError: ""
    property string chatStorageNotice: ""
    // Helper steps still to run and the one running.
    property var chatQueue: []
    property string chatOp: ""
    property string chatOpSource: ""
    property int chatOpGeneration: -1
    // Seeded in Component.onCompleted; see ChatStorage.firstRun.
    property int chatOpRun: 0
    readonly property bool chatVaultPrompting: root.chatOp === "create" || root.chatOp === "unlock"
    readonly property bool chatStorageReady: root.chatStorageMode === "encrypted"
        && root.chatVaultState === "unlocked"
        && !root.chatVaultHold
        && root.chatPreparedGeneration === root.chatGeneration
        && root.chatProfilePath !== ""
        && root.chatProfileName !== ""
    readonly property var chatCard: ChatStorage.cardFor({
        mode: root.chatStorageMode,
        state: root.chatVaultState,
        // Quiet re-checks while the saved profile is open don't show a card.
        op: root.chatOp === "keep" ? "" : ChatStorage.stepOperation(root.chatOp),
        error: root.chatVaultError,
        hold: root.chatVaultHold,
        privateSession: root.chatPrivateSession,
        ready: root.chatStorageReady
    })

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

    // --- Stay signed in: helper steps, run one at a time --------------------

    // fresh: queue a status even while one started earlier is running.
    function chatEnqueue(steps, fresh) {
        root.chatQueue = ChatStorage.enqueueSteps(root.chatQueue, steps, root.chatOp, fresh === true)
        if (root.chatOp === "")
            Qt.callLater(root.chatNext)
    }

    function chatCommand(step, run) {
        switch (step) {
        case "prepare":
            return ChatStorage.webDataCommand("prepare", "encrypted",
                root.chatAppletId, root.chatGeneration, null, run)
        case "keep":
            return ChatStorage.webDataCommand("remove", "encrypted",
                root.chatAppletId, null, root.chatGeneration, run)
        case "remove":
        case "leave-remove":
            return ChatStorage.webDataCommand("remove", "encrypted",
                root.chatAppletId, null, null, run)
        default:
            return ChatStorage.vaultCommand(ChatStorage.stepOperation(step), run, root.chatAppletId)
        }
    }

    function chatNext() {
        if (root.chatOp !== "" || root.chatQueue.length === 0)
            return
        // Leave steps are dropped once Stay signed in is back on.
        var next = ChatStorage.nextStep(root.chatQueue, {
            mode: root.chatStorageMode,
            state: root.chatVaultState,
            wantsSaved: root.chatWantsSaved()
        })
        root.chatQueue = next.queue
        var step = next.step
        if (step === "")
            return
        if (step === "wait" || step === "leave-wait") {
            // Gives Qt WebEngine a moment to close the profile's files.
            root.chatOp = step
            chatWaitTimer.start()
            return
        }
        root.chatOpRun = ChatStorage.nextRun(root.chatOpRun)
        var command = root.chatCommand(step, root.chatOpRun)
        if (command === "") {
            root.chatFinish(step, {ok: false, error: "failed"})
            return
        }
        root.chatOp = step
        root.chatOpGeneration = root.chatGeneration
        root.chatOpSource = command
        storageSource.connectSource(command)
    }

    function chatWantsSaved() {
        return root.chatStorageMode === "encrypted" && !root.chatVaultHold
            && !root.chatPrivateSession && root.chatVaultState === "unlocked"
            && root.chatProfilePath !== ""
    }

    function chatFinish(step, reply) {
        root.chatOp = ""
        root.chatOpSource = ""
        switch (step) {
        case "status":
        case "leave-status":
            // Another widget holds the folder's lock (e.g. its passphrase
            // window is open): keep what we knew.
            if (!reply.ok && reply.error === "busy" && root.chatVaultState !== "")
                break
            if (reply.ok && reply.state) {
                root.chatVaultState = reply.state
                root.chatVaultMissing = reply.missing || []
            } else {
                root.chatVaultState = "error"
                root.chatVaultError = reply.error || "failed"
            }
            if (root.chatVaultState !== "unlocked")
                root.chatPreparedGeneration = -1
            else if (root.chatWantsSaved()
                     && root.chatPreparedGeneration !== root.chatGeneration)
                root.chatEnqueue(["prepare"])
            break
        case "prepare":
            if (reply.ok && root.chatOpGeneration === root.chatGeneration && root.chatWantsSaved()) {
                root.chatVaultError = ""
                root.chatPreparedGeneration = root.chatGeneration
                // Old generations of this widget (e.g. after Clear) go away.
                root.chatEnqueue(["keep"])
                // Another widget may lock the folder while the view opens it.
                chatRecheckTimer.restart()
            } else if (!reply.ok) {
                root.chatPreparedGeneration = -1
                root.chatVaultError = reply.error === "not-verified" || reply.error === "stale-mount"
                    ? reply.error : "prepare-failed"
                root.chatEnqueue(["status"])
            }
            break
        case "keep":
            break
        case "remove":
            if (!reply.ok && root.chatStorageMode === "encrypted")
                root.chatVaultError = "remove-failed"
            break
        case "create":
        case "unlock":
        case "lock":
            if (!reply.ok)
                root.chatVaultError = step === "lock" && reply.error === "busy"
                    ? "lock-busy" : reply.error || "failed"
            root.chatEnqueue(["status"])
            break
        case "destroy":
            // Damaged folder, confirmed in the Chat tab; then Create.
            if (!reply.ok)
                root.chatVaultError = reply.error || "failed"
            var destroyed = ChatStorage.afterDestroy(reply)
            if (destroyed.state !== "") {
                root.chatVaultState = destroyed.state
                root.chatVaultMissing = []
                root.chatPreparedGeneration = -1
            }
            root.chatEnqueue(["status"])
            break
        case "leave-remove":
        case "leave-lock":
            // leave-status reports how the folder ended up.
            break
        case "leave-destroy":
            if (!reply.ok && root.chatStorageMode === "memory")
                root.chatStorageNotice = "delete-failed"
            var outcome = ChatStorage.afterDestroy(reply)
            if (outcome.state !== "") {
                root.chatVaultState = outcome.state
                root.chatVaultMissing = []
                root.chatPreparedGeneration = -1
            }
            root.chatEnqueue(outcome.steps)
            break
        }
        Qt.callLater(root.chatNext)
    }

    // ChatView's requests (buttons and lifecycle).
    function chatStorageRequest(action) {
        switch (action) {
        case "open":
            // The Chat view starts: never trust an earlier answer.
            root.chatPreparedGeneration = -1
            root.chatEnqueue(["status"])
            break
        case "recheck":
            root.chatEnqueue(["status"])
            break
        case "retry":
            root.chatVaultHold = false
            root.chatVaultError = ""
            root.chatPreparedGeneration = -1
            root.chatEnqueue(["status"])
            break
        case "create":
        case "unlock":
            root.chatVaultHold = false
            root.chatVaultError = ""
            root.chatEnqueue([action])
            break
        case "private":
            root.chatPrivateSession = true
            root.chatVaultError = ""
            break
        case "saved-session":
            root.chatPrivateSession = false
            root.chatVaultHold = false
            root.chatVaultError = ""
            root.chatEnqueue(["status"])
            break
        case "lock":
            // Destroy the profile first (ready turns false), then unmount.
            // A busy folder is reported, never forced.
            root.chatVaultHold = true
            root.chatVaultError = ""
            root.chatPreparedGeneration = -1
            root.chatEnqueue(["wait", "lock"])
            break
        case "clear-saved":
            root.chatVaultHold = true
            root.chatPreparedGeneration = -1
            root.chatSetGeneration(ChatStorage.nextGeneration(root.chatGeneration))
            root.chatVaultError = "cleared"
            root.chatEnqueue(["wait", "remove", "lock"])
            break
        case "delete-damaged":
            if (root.chatVaultState !== "damaged")
                break
            root.chatVaultError = ""
            root.chatEnqueue(["destroy"])
            break
        case "dismiss-notice":
            root.chatStorageNotice = ""
            break
        }
    }

    function chatSetGeneration(generation) {
        root.chatGeneration = generation
        if (Plasmoid.configuration.chatProfileGeneration !== generation)
            Plasmoid.configuration.chatProfileGeneration = generation
    }

    function chatModeChanged() {
        if (root.chatGeneration < 0)
            return
        var previous = root.chatModeSeen
        root.chatModeSeen = root.chatStorageMode
        if (previous === root.chatStorageMode)
            return
        root.chatVaultHold = false
        root.chatPrivateSession = false
        root.chatVaultError = ""
        root.chatPreparedGeneration = -1
        chatRecheckTimer.stop()
        root.chatQueue = ChatStorage.queueForMode(root.chatQueue, root.chatStorageMode)
        if (root.chatStorageMode === "encrypted") {
            // Never trust a state read while leave steps may have run.
            root.chatStorageNotice = ""
            root.chatVaultState = ""
            root.chatEnqueue(["status"], true)
        } else {
            // Leaving Stay signed in deletes the encrypted folder (confirmed
            // in the settings). The view is back to private already.
            root.chatEnqueue(["leave-wait", "leave-remove", "leave-lock", "leave-status", "leave-destroy"])
        }
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

    Plasma5Support.DataSource {
        id: storageSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            storageSource.disconnectSource(source)
            if (source !== root.chatOpSource)
                return
            // Only stdout's known words are used; stderr is never read.
            root.chatFinish(root.chatOp, ChatStorage.replyFor(data["exit code"], data["stdout"]))
        }
    }

    Timer {
        id: chatWaitTimer
        interval: 1000
        repeat: false
        onTriggered: {
            root.chatOp = ""
            root.chatNext()
        }
    }

    // Rechecks the folder shortly after the saved profile is built; a busy
    // reply keeps things as they are.
    Timer {
        id: chatRecheckTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (root.chatStorageReady)
                root.chatEnqueue(["status"])
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
        root.chatGeneration = root.chatConfiguredGeneration
        root.chatModeSeen = root.chatStorageMode
        root.chatOpRun = ChatStorage.firstRun(Date.now(), Math.random())
    }

    onChatStorageModeChanged: root.chatModeChanged()
    // A settings dialog opened earlier may write back an old generation.
    onChatConfiguredGenerationChanged: {
        if (root.chatGeneration >= 0 && root.chatConfiguredGeneration !== root.chatGeneration)
            Plasmoid.configuration.chatProfileGeneration = root.chatGeneration
    }

    onTrackedProvidersChanged: {
        root.rebuildVisibleProviders()
        root.refresh()
    }
    onExpandedChanged: {
        if (root.expanded) {
            root.refresh()
            if (root.chatStorageMode === "encrypted" && root.chatVaultState !== "")
                root.chatEnqueue(["status"])
        } else
            root.chatPinned = false
    }
    onChatSiteIdsChanged: root.syncChatSite()
    onChatSiteIdChanged: {
        if (root.chatSiteId !== OllamaChat.ENTRY.id)
            root.chatWebSiteId = root.chatSiteId
    }

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
