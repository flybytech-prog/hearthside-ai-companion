import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support
import "ChatSites.js" as ChatSites
import "ChatStorage.js" as ChatStorage

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
    property string cfg_chatCustomUrls: "{}"
    property string cfg_chatCustomUrlsDefault: "{}"
    property string cfg_chatSignInStorage: "memory"
    property string cfg_chatSignInStorageDefault: "memory"
    // Written only by main.qml; kept in step so Apply never writes back an
    // old value.
    property int cfg_chatProfileGeneration: 0
    property int cfg_chatProfileGenerationDefault: 0

    // Page-local only; the advanced section always starts collapsed.
    property bool showAdvanced: false

    // Stay signed in. The mode the page opened with decides whether turning
    // it off needs a confirmation (applying it deletes the encrypted folder).
    property string savedSignInMode: "memory"
    readonly property string signInMode: ChatStorage.normalizeMode(page.cfg_chatSignInStorage)
    property bool confirmingOff: false
    property bool confirmingDelete: false
    // Encrypted folder, as the helper reports it: "", absent, locked,
    // unlocked, unavailable, error. Never a path.
    property string vaultState: ""
    property var vaultMissing: []
    property string vaultOp: ""
    property string vaultSourceName: ""
    // Seeded in Component.onCompleted; see ChatStorage.firstRun.
    property int vaultRun: 0
    // Only makes the helper's source name unique; 0 if the id is odd.
    readonly property int vaultApplet: Math.max(0, ChatStorage.validInt(Plasmoid.id))
    property string vaultMessage: ""

    function syncSignInChoice() {
        offChoice.checked = page.signInMode === "memory"
        encryptedChoice.checked = page.signInMode === "encrypted"
    }

    function chooseSignIn(mode) {
        page.confirmingOff = false
        if (mode === "memory" && page.signInMode === "encrypted"
                && page.savedSignInMode === "encrypted") {
            page.confirmingOff = true
            page.syncSignInChoice()
            return
        }
        page.cfg_chatSignInStorage = mode
    }

    function runVault(op) {
        if (page.vaultOp !== "")
            return
        page.vaultRun = ChatStorage.nextRun(page.vaultRun)
        var command = ChatStorage.vaultCommand(op, page.vaultRun, page.vaultApplet)
        if (command === "")
            return
        page.vaultOp = op
        page.vaultSourceName = command
        page.confirmingDelete = false
        if (op !== "status")
            page.vaultMessage = ""
        vaultSource.connectSource(command)
    }

    function finishVault(op, reply) {
        page.vaultOp = ""
        page.vaultSourceName = ""
        if (op === "status") {
            page.vaultState = reply.ok && reply.state ? reply.state : "error"
            page.vaultMissing = reply.missing || []
            return
        }
        if (reply.ok)
            page.vaultMessage = op === "destroy" ? "deleted" : "changed"
        else
            page.vaultMessage = reply.error === "cancelled" || reply.error === "empty-passphrase"
                ? "" : reply.error
        page.runVault("status")
    }

    function vaultText(code) {
        switch (code) {
        case "":
            return ""
        case "changed":
            return i18n("Passphrase changed.")
        case "deleted":
            return i18n("Encrypted folder deleted.")
        case "wrong-passphrase":
            return i18n("Wrong passphrase. Nothing was changed.")
        case "not-locked":
            return i18n("Lock the encrypted folder from the Chat tab first.")
        case "busy":
            return i18n("The encrypted folder is busy. Try again in a moment.")
        case "damaged":
            return i18n("The encrypted folder is damaged and can't be opened. Nothing was changed.")
        default:
            return i18n("That didn't work. Nothing was changed.")
        }
    }

    function vaultStateText() {
        switch (page.vaultState) {
        case "absent":
            return i18n("No encrypted folder has been created.")
        case "locked":
            return i18n("The encrypted folder is locked.")
        case "unlocked":
            return i18n("The encrypted folder is unlocked. Lock it from the Chat tab to change its passphrase or delete it.")
        case "unavailable":
            return i18n("gocryptfs isn't installed.")
        case "damaged":
            return i18n("The encrypted folder is damaged and can't be opened. Delete it to start again with a new one.")
        case "":
            return i18n("Checking…")
        default:
            return i18n("Couldn't check the encrypted folder.")
        }
    }

    onCfg_chatSignInStorageChanged: page.syncSignInChoice()

    Component.onCompleted: {
        page.savedSignInMode = page.signInMode
        page.syncSignInChoice()
        page.vaultRun = ChatStorage.firstRun(Date.now(), Math.random())
        page.runVault("status")
    }

    // main.qml may move to a new generation while this page is open.
    Connections {
        target: Plasmoid.configuration
        function onValueChanged(key, value) {
            if (key === "chatProfileGeneration")
                page.cfg_chatProfileGeneration = value
        }
    }

    Plasma5Support.DataSource {
        id: vaultSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            vaultSource.disconnectSource(source)
            if (source !== page.vaultSourceName)
                return
            page.finishVault(page.vaultOp, ChatStorage.replyFor(data["exit code"], data["stdout"]))
        }
    }

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

    // Saved custom address of one site, "" when it uses the built-in one.
    function savedCustomUrl(siteId) {
        var map = ChatSites.parseCustomUrls(page.cfg_chatCustomUrls)
        return Object.prototype.hasOwnProperty.call(map, siteId) ? map[siteId] : ""
    }

    // Only valid or empty addresses are ever written; "" removes the entry.
    function setCustomUrl(siteId, url) {
        var map = ChatSites.parseCustomUrls(page.cfg_chatCustomUrls)
        if (url === "")
            delete map[siteId]
        else
            map[siteId] = url
        page.cfg_chatCustomUrls = ChatSites.serializeCustomUrls(map)
    }

    function customUrlError(siteId, code) {
        switch (code) {
        case "":
            return ""
        case "too-long":
            return i18n("This address is too long.")
        case "whitespace":
            return i18n("Addresses can't contain spaces or line breaks.")
        case "userinfo":
            return i18n("Addresses with a user name or password aren't allowed.")
        case "scheme":
            return ChatSites.byId(siteId) && ChatSites.byId(siteId).local === true
                ? i18n("Use an address that starts with https:// or http://.")
                : i18n("Use an address that starts with https://.")
        case "http-not-loopback":
            return i18n("http is allowed only for this computer. Use https or an SSH tunnel.")
        case "loopback-not-allowed":
            return i18n("Addresses on this computer are allowed only for Local.")
        default:
            return i18n("This isn't a valid web address.")
        }
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
                "By default chat sites open in a private, in-memory browser profile. You are signed out on every Plasma restart; nothing is saved to disk. Clear chat data signs you out immediately."
            )
        }

        Kirigami.Heading {
            level: 3
            text: i18n("Stay signed in")
        }

        QQC2.RadioButton {
            id: offChoice
            text: i18n("Off: sign in again after every Plasma restart")
            onToggled: if (checked) page.chooseSignIn("memory")
        }
        QQC2.RadioButton {
            id: encryptedChoice
            text: i18n("Encrypted: keep sign-ins in a passphrase-protected folder")
            onToggled: if (checked) page.chooseSignIn("encrypted")
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.72
            text: i18n(
                "Sign-ins and site data, such as cached conversations, are kept in an encrypted folder made with gocryptfs. You enter its passphrase once per Plasma session in the Chat tab; until then you can use a private session. If you forget the passphrase, the saved data is lost: there is no recovery. While the folder is unlocked, programs running as you can read it. Clear chat data deletes the saved sign-ins and locks the folder."
            )
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: page.vaultState === "unavailable"
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: i18n("This needs gocryptfs, which isn't installed. Install it with:")
            }
            QQC2.TextField {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                text: ChatStorage.installCommand(page.vaultMissing)
            }
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.confirmingOff
            type: Kirigami.MessageType.Warning
            text: i18n("Turn off Stay signed in? When you apply this, the encrypted folder and every sign-in saved in it are deleted, for all Hearthside widgets. This can't be undone.")
            actions: [
                Kirigami.Action {
                    text: i18n("Turn off and delete")
                    icon.name: "edit-delete"
                    onTriggered: {
                        page.confirmingOff = false
                        page.cfg_chatSignInStorage = "memory"
                    }
                },
                Kirigami.Action {
                    text: i18n("Cancel")
                    icon.name: "dialog-cancel"
                    onTriggered: {
                        page.confirmingOff = false
                        page.syncSignInChoice()
                    }
                }
            ]
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

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        QQC2.CheckBox {
            text: i18n("Show advanced settings")
            checked: page.showAdvanced
            onToggled: page.showAdvanced = checked
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: page.showAdvanced
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading {
                level: 2
                text: i18n("Encrypted folder")
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: page.vaultStateText()
            }

            RowLayout {
                spacing: Kirigami.Units.smallSpacing

                QQC2.Button {
                    text: i18n("Change passphrase…")
                    icon.name: "document-edit"
                    enabled: page.vaultState === "locked" && page.vaultOp === ""
                    onClicked: page.runVault("change-passphrase")
                }
                QQC2.Button {
                    text: i18n("Delete encrypted folder…")
                    icon.name: "edit-delete"
                    enabled: (page.vaultState === "locked" || page.vaultState === "damaged")
                        && page.vaultOp === ""
                    onClicked: page.confirmingDelete = true
                }
                QQC2.BusyIndicator {
                    visible: page.vaultOp !== ""
                    running: visible
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: page.confirmingDelete
                type: Kirigami.MessageType.Warning
                text: i18n("Delete the encrypted folder? Every sign-in saved in it is lost, for all Hearthside widgets. This can't be undone.")
                actions: [
                    Kirigami.Action {
                        text: i18n("Delete")
                        icon.name: "edit-delete"
                        onTriggered: page.runVault("destroy")
                    },
                    Kirigami.Action {
                        text: i18n("Cancel")
                        icon.name: "dialog-cancel"
                        onTriggered: page.confirmingDelete = false
                    }
                ]
            }

            QQC2.Label {
                Layout.fillWidth: true
                visible: page.vaultMessage !== ""
                wrapMode: Text.WordWrap
                color: page.vaultMessage === "changed" || page.vaultMessage === "deleted"
                    ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                text: page.vaultText(page.vaultMessage)
            }

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            Kirigami.Heading {
                level: 2
                text: i18n("Custom addresses")
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.72
                text: i18n(
                    "Addresses are saved in your Plasma configuration file. Don't put passwords, tokens or other secrets in them. Leave empty to use the built-in address."
                )
            }

            Repeater {
                model: ChatSites.sites

                delegate: ColumnLayout {
                    id: urlRow
                    required property var modelData
                    // Validation code of the text in the field; "" when valid.
                    property string errorCode: ""
                    // Saved value this row last saw or wrote.
                    property string savedUrl: ""
                    // Saved value when the page opened or when it last changed
                    // elsewhere (Defaults); written back while the text is invalid.
                    property string baseline: ""
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    function load(saved) {
                        urlRow.baseline = saved
                        urlRow.savedUrl = saved
                        urlRow.errorCode = ""
                        if (urlField.text.trim() !== saved)
                            urlField.text = saved
                    }

                    function syncFromConfig() {
                        // Our own writes and other rows' writes leave this
                        // row's saved value as last seen; keep the field as is.
                        var saved = page.savedCustomUrl(urlRow.modelData.id)
                        if (saved !== urlRow.savedUrl)
                            urlRow.load(saved)
                    }

                    function edit(text) {
                        var persist = ChatSites.customUrlToPersist(
                            urlRow.modelData.id, text, urlRow.baseline)
                        urlRow.errorCode = persist.error
                        urlRow.savedUrl = persist.url
                        page.setCustomUrl(urlRow.modelData.id, persist.url)
                    }

                    Component.onCompleted: urlRow.load(page.savedCustomUrl(urlRow.modelData.id))

                    Connections {
                        target: page
                        function onCfg_chatCustomUrlsChanged() {
                            urlRow.syncFromConfig()
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        text: urlRow.modelData.name
                        elide: Text.ElideRight
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.TextField {
                            id: urlField
                            Layout.fillWidth: true
                            placeholderText: urlRow.modelData.url
                            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoPredictiveText
                                | Qt.ImhNoAutoUppercase
                            Accessible.name: i18n("Address for %1", urlRow.modelData.name)
                            onTextEdited: urlRow.edit(urlField.text)
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-undo"
                            display: QQC2.AbstractButton.IconOnly
                            text: i18n("Use the built-in address")
                            enabled: urlField.text !== ""
                            onClicked: {
                                urlField.text = ""
                                urlRow.edit("")
                            }
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: urlRow.errorCode !== ""
                        wrapMode: Text.WordWrap
                        color: Kirigami.Theme.negativeTextColor
                        text: page.customUrlError(urlRow.modelData.id, urlRow.errorCode)
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: urlRow.modelData.local === true
                        wrapMode: Text.WordWrap
                        opacity: 0.72
                        text: i18n(
                            "http is allowed only for this computer (localhost, 127.0.0.1, [::1]). For a server on another machine use https or an SSH tunnel."
                        )
                    }
                }
            }
        }
    }
}
