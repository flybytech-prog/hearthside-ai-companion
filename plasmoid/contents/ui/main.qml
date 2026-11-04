import QtCore
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami
import org.kde.notification
import "ProviderCatalog.js" as Catalog
import "RefreshGate.js" as RefreshGate
import "SnapshotLogic.js" as SnapshotLogic
import "ChatSites.js" as ChatSites
import "ChatStorage.js" as ChatStorage
import "OllamaChat.js" as OllamaChat
import "SettingsLogic.js" as SettingsLogic
import "AlertLogic.js" as AlertLogic

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
    property bool chatDialogOpen: false
    // Settings → General → Show tabs. Chat also needs an enabled site.
    readonly property var popupTabs: SettingsLogic.visibleTabs(
        Plasmoid.configuration.showUsageTab,
        Plasmoid.configuration.showChatTab,
        root.chatSiteIds.length > 0)
    // A hidden Chat tab builds no chat view; a hidden Usage tab runs no
    // usage helper.
    readonly property bool chatShown: root.popupTabs.chat
    readonly property bool usageShown: root.popupTabs.usage
    // The tab the popup shows: popupTab while it is visible, else the other.
    readonly property string shownTab: SettingsLogic.shownTab(root.popupTab, root.popupTabs)
    readonly property real popupScale: SettingsLogic.popupScale(Plasmoid.configuration.popupSize)
    readonly property bool tooltipShowsUsage: Plasmoid.configuration.tooltipShowsUsage !== false
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
    // Per-site zoom {siteId: factor} for the web sites and Ollama. Read from
    // the configuration at start; Ctrl+= / Ctrl+- / Ctrl+0 change it here and
    // zoomWriteTimer stores it a moment later.
    readonly property var chatZoomIds: ChatSites.siteIds().concat([OllamaChat.ENTRY.id])
    property var chatZoom: ({})

    // Settings → General → Keyboard shortcut opens.
    readonly property string shortcutTarget:
        SettingsLogic.normalizeShortcutTarget(Plasmoid.configuration.shortcutOpens)
    // The shortcut opened the Ollama chat: its message box takes the focus.
    signal ollamaFocusRequested()
    // What the last shortcut press asked for: open (true) or closed.
    property bool shortcutOpen: false
    // Ollama is on and the Chat tab can show it: text dropped on the panel
    // icon opens it.
    readonly property bool ollamaDropTarget: root.chatShown
        && root.chatSiteIds.indexOf(OllamaChat.ENTRY.id) >= 0
    // Text dropped on the panel icon, until the popup puts it into Ollama's
    // message box (FullRepresentation.takePendingDrop). Runtime only, never
    // sent from here.
    property string pendingDrop: ""

    // Usage alerts, memory only: after a Plasma restart the first reading is
    // a baseline again.
    property var alertState: ({})

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
    // A helper step runs or waits to run; Lock automatically holds off.
    readonly property bool chatStorageBusy: root.chatOp !== "" || root.chatQueue.length > 0
    // Lock automatically after this many idle minutes; 0 = never.
    readonly property int chatAutoLockMinutes:
        ChatStorage.normalizeAutoLock(Plasmoid.configuration.chatAutoLockMinutes)
    // The running lock was started by Lock automatically.
    property bool chatAutoLocking: false
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
    readonly property var configuredMetrics: configuredObject(
        Plasmoid.configuration.providerMetrics,
        {"claude": ["weekly"], "codex": ["weekly"]}
    )
    readonly property var tooltipGroups: tooltipProviderGroups()
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

    // The providers the Usage tab shows, each with its selected metrics
    // (else its default metric).
    function tooltipProviderGroups() {
        var result = []
        var shown = root.snapshot.providers || []
        for (var index = 0; index < shown.length; index++) {
            var providerId = shown[index].provider_id
            var descriptor = Catalog.byId(providerId)
            if (!descriptor)
                continue
            var metrics = root.selectedMetrics(providerId)
            if (metrics.length === 0 && Catalog.metric(providerId, descriptor.default_metric) !== null)
                metrics = [descriptor.default_metric]
            if (metrics.length === 0)
                continue
            result.push({
                provider_id: providerId,
                descriptor: descriptor,
                provider: shown[index],
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
        if (!root.usageShown)
            return
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
            // Destroying the profile writes its cookies and site storage and
            // closes its files at once (measured: done within 0.2 s, also
            // with 150 cookies and 1 MB of site storage); the second is
            // margin. The helper's unmount fails as busy, never loses data,
            // while any file is still open.
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
            var automatic = step === "lock" && root.chatAutoLocking
            if (step === "lock")
                root.chatAutoLocking = false
            if (automatic && !reply.ok && reply.error === "busy") {
                // Never forced: keep the saved sign-ins open; ChatView tries
                // again after the next idle period.
                root.chatVaultHold = false
                root.chatVaultError = ""
            } else if (!reply.ok)
                root.chatVaultError = step === "lock" && reply.error === "busy"
                    ? "lock-busy" : reply.error || "failed"
            else if (automatic)
                root.chatVaultError = "auto-locked"
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
            root.chatAutoLocking = false
            root.chatVaultHold = true
            root.chatVaultError = ""
            root.chatPreparedGeneration = -1
            root.chatEnqueue(["wait", "lock"])
            break
        case "auto-lock":
            // Same as Lock; ChatView asks only while the saved web chat is
            // hidden and no helper step runs.
            if (!root.chatStorageReady || root.chatStorageBusy)
                break
            root.chatAutoLocking = true
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
        root.chatAutoLocking = false
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

    // Plasma's activation (the keyboard shortcut): closes an open popup,
    // else opens it on the target from Settings → General.
    function openFromShortcut() {
        root.shortcutOpen = !root.expanded
        if (root.shortcutOpen) {
            var plan = SettingsLogic.shortcutPlan(root.shortcutTarget, root.popupTabs,
                root.chatSiteIds.indexOf(OllamaChat.ENTRY.id) >= 0)
            if (plan.tab !== "")
                root.popupTab = plan.tab
            if (plan.site !== "")
                root.chatSiteId = plan.site
            root.expanded = true
            if (plan.focusInput)
                root.ollamaFocusRequested()
        }
        // Plasma expands the popup itself right after this handler (spike
        // K1), so the close is applied once it is done.
        Qt.callLater(root.finishShortcut)
    }

    // Text dropped on the panel icon: open the popup on Ollama with it in the
    // message box. One character over the limit is enough for the view to
    // refuse it.
    function dropToOllama(text) {
        if (typeof text !== "string" || text === "" || !root.ollamaDropTarget)
            return
        root.pendingDrop = text.length > OllamaChat.MAX_PROMPT_CHARS
            ? text.slice(0, OllamaChat.MAX_PROMPT_CHARS + 1) : text
        root.popupTab = "chat"
        root.chatSiteId = OllamaChat.ENTRY.id
        root.expanded = true
    }

    function finishShortcut() {
        if (root.expanded !== root.shortcutOpen)
            root.expanded = root.shortcutOpen
    }

    // factor must be one of ZOOM_STEPS; 1.0 removes the site's zoom.
    function setSiteZoom(siteId, factor) {
        if (root.chatZoomIds.indexOf(siteId) < 0 || SettingsLogic.ZOOM_STEPS.indexOf(factor) < 0)
            return
        root.chatZoom = SettingsLogic.parseZoomMap(
            SettingsLogic.zoomMapToPersist(root.chatZoom, siteId, factor), root.chatZoomIds)
        zoomWriteTimer.restart()
    }

    // direction: +1 bigger, -1 smaller, 0 back to 100%.
    function stepSiteZoom(siteId, direction) {
        root.setSiteZoom(siteId, SettingsLogic.zoomStep(
            SettingsLogic.zoomFor(root.chatZoom, siteId), direction))
    }

    // Fresh percentage windows of the providers this run reported, for the
    // metrics the Usage tab shows. Stale and failed providers are left out,
    // so they keep their alert state.
    function alertReadings(providerIds) {
        var readings = []
        var groups = root.tooltipProviderGroups()
        for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
            var group = groups[groupIndex]
            if (providerIds.indexOf(group.provider_id) < 0 || group.provider.status !== "ok")
                continue
            for (var metricIndex = 0; metricIndex < group.metrics.length; metricIndex++) {
                var window = SnapshotLogic.windowFor(group.provider, group.metrics[metricIndex])
                if (!window || typeof window.used_percent !== "number")
                    continue
                var resetsAt = typeof window.resets_at === "string"
                    ? new Date(window.resets_at).getTime() : NaN
                readings.push({
                    providerId: group.provider_id,
                    metricId: group.metrics[metricIndex],
                    usedPercent: window.used_percent,
                    resetsAtMs: isFinite(resetsAt) ? resetsAt : null
                })
            }
        }
        return readings
    }

    function checkAlerts(results) {
        if (!root.usageShown)
            return
        var providerIds = []
        var list = Array.isArray(results) ? results : []
        for (var index = 0; index < list.length; index++) {
            if (list[index] && typeof list[index].provider_id === "string")
                providerIds.push(list[index].provider_id)
        }
        var result = AlertLogic.evaluate(root.alertState, root.alertReadings(providerIds), {
            lowEnabled: Plasmoid.configuration.alertLowEnabled === true,
            lowPercent: SettingsLogic.normalizeAlertPercent(Plasmoid.configuration.alertLowPercent),
            resetEnabled: Plasmoid.configuration.alertResetEnabled === true
        })
        root.alertState = result.state
        for (var alertIndex = 0; alertIndex < result.alerts.length; alertIndex++)
            root.notifyAlert(result.alerts[alertIndex])
    }

    // Plasma reads a little markup in a notification's body (its title is
    // plain text): the body's name is escaped.
    function markupSafe(text) {
        return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // Catalog names and a whole percentage only; never helper text.
    function notifyAlert(alert) {
        var descriptor = Catalog.byId(alert.providerId)
        var metric = Catalog.metric(alert.providerId, alert.metricId)
        if (!descriptor || !metric)
            return
        var notification = alertNotification.createObject(root, {
            reset: alert.kind === "reset",
            providerName: descriptor.display_name,
            metricName: root.markupSafe(metric.title),
            percentLeft: Math.max(0, Math.min(100, Math.round(Number(alert.left) || 0)))
        })
        if (notification)
            notification.sendEvent()
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
                var payload = null
                try {
                    payload = JSON.parse(output)
                    root.applySnapshot(payload)
                } catch (error) {
                    payload = null
                    root.lastError = i18n("Could not parse helper output")
                }
                if (payload)
                    root.checkAlerts(payload.providers)
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

    // Starts (and refreshes at once) when the Usage tab is shown again.
    Timer {
        interval: root.refreshInterval * 1000
        running: root.usageShown
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Stores the zoom a second after the last Ctrl+= / Ctrl+- / Ctrl+0, so
    // holding a key writes the configuration once.
    Timer {
        id: zoomWriteTimer
        interval: 1000
        repeat: false
        onTriggered: {
            Plasmoid.configuration.chatSiteZoom = SettingsLogic.zoomMapToPersist(root.chatZoom, "", 1.0)
        }
    }

    // One usage alert; destroyed by itself once shown (autoDelete).
    Component {
        id: alertNotification

        Notification {
            property bool reset: false
            property string providerName: ""
            property string metricName: ""
            property int percentLeft: 0

            componentName: "hearthside"
            eventId: reset ? "usageReset" : "usageLow"
            iconName: "hearthside"
            urgency: Notification.NormalUrgency
            autoDelete: true
            title: reset ? i18n("%1 has reset", providerName) : i18n("%1 is running low", providerName)
            text: reset ? i18n("%1 is available again.", metricName) : i18n("%1: %2% left", metricName, percentLeft)
        }
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
        root.popupTab = SettingsLogic.normalizeDefaultTab(Plasmoid.configuration.popupDefaultTab)
        root.chatGeneration = root.chatConfiguredGeneration
        root.chatModeSeen = root.chatStorageMode
        root.chatOpRun = ChatStorage.firstRun(Date.now(), Math.random())
        root.chatZoom = SettingsLogic.parseZoomMap(Plasmoid.configuration.chatSiteZoom, root.chatZoomIds)
    }

    // The zoom map changed outside this widget (e.g. Defaults in the
    // settings); a write of our own still waiting wins.
    readonly property string configuredZoom: Plasmoid.configuration.chatSiteZoom
    onConfiguredZoomChanged: {
        if (!zoomWriteTimer.running)
            root.chatZoom = SettingsLogic.parseZoomMap(root.configuredZoom, root.chatZoomIds)
    }

    // A zoom still waiting is stored before the widget goes (Plasma quits,
    // the widget is removed), through the timer's own handler.
    Component.onDestruction: {
        if (zoomWriteTimer.running) {
            zoomWriteTimer.stop()
            zoomWriteTimer.triggered()
        }
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
            if (root.chatShown && root.chatStorageMode === "encrypted" && root.chatVaultState !== "")
                root.chatEnqueue(["status"])
        }
    }
    onChatSiteIdsChanged: root.syncChatSite()
    // Settings → General → Open on.
    readonly property string configuredDefaultTab:
        SettingsLogic.normalizeDefaultTab(Plasmoid.configuration.popupDefaultTab)
    onConfiguredDefaultTabChanged: root.popupTab = root.configuredDefaultTab
    onChatSiteIdChanged: {
        if (root.chatSiteId !== OllamaChat.ENTRY.id)
            root.chatWebSiteId = root.chatSiteId
    }

    // The keyboard shortcut (set in Plasma's Keyboard Shortcuts tab) goes
    // through openFromShortcut, never Plasma's plain toggle.
    activationTogglesExpanded: false
    Connections {
        target: Plasmoid
        function onActivated() {
            root.openFromShortcut()
        }
    }

    // Settings → General → Keep the popup open; also while a dialog is open.
    hideOnWindowDeactivate: !Plasmoid.configuration.chatKeepOpen && !root.chatDialogOpen

    Plasmoid.icon: Qt.resolvedUrl("../images/hearthside.svg")
    Plasmoid.busy: root.usageShown && !root.hasData && root.lastError === ""
    toolTipMainText: i18n("Hearthside")
    // Provider names, plans and helper errors: never rich text.
    toolTipTextFormat: Text.PlainText
    toolTipSubText: {
        if (!root.usageShown || !root.tooltipShowsUsage)
            return ""
        if (root.lastError !== "" && !root.hasData)
            return i18n("Error: %1", root.lastError)
        if (!root.hasData)
            return i18n("Loading…")
        if (root.tooltipGroups.length === 0)
            return i18n("No usage to show.")
        var lines = []
        for (var groupIndex = 0; groupIndex < root.tooltipGroups.length; groupIndex++) {
            var group = root.tooltipGroups[groupIndex]
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
            visible: root.usageShown
            onTriggered: root.refresh()
        }
    ]
}
