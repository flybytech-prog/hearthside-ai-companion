import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "PromptLibrary.js" as PromptLibrary

// The prompt library in the popup (D67): saved prompts and personalities
// while the encrypted folder is unlocked, else ones kept for this session
// only. Their text is user text: shown as plain text only, never saved in
// the configuration. With Ollama a prompt goes into the message box; on a
// web site it is copied to the clipboard on a click (pages are never
// scripted, D54).
ColumnLayout {
    id: panel

    // [{id, kind, text}]: saved items (id > 0), then this session's (id < 0).
    property var items: []
    // The encrypted folder is unlocked: items are saved (helper, kdialog).
    property bool saved: false
    // "", loading, ready, error (main.qml's libraryState).
    property string libraryState: ""
    property string error: ""
    // Stay signed in is Encrypted (else there is nowhere to save).
    property bool encryptedMode: false
    // Ollama is shown: prompts are inserted, personalities used.
    property bool forOllama: false
    // A helper job is running or waiting.
    property bool busy: false
    // An item waiting for its Remove confirmation (0 = none).
    property int confirmingRemove: 0
    property bool copied: false

    readonly property var prompts: PromptLibrary.itemsOf(panel.items, "prompt")
    readonly property var personas: PromptLibrary.itemsOf(panel.items, "persona")

    signal useRequested(string text)
    signal personaRequested(var entry)
    signal addRequested(string kind)
    signal replaceRequested(int id)
    signal removeRequested(int id)
    signal sessionAddRequested(string kind, string text)
    signal sessionRemoveRequested(int id)
    signal closeRequested()

    spacing: Kirigami.Units.smallSpacing

    // A user click only: through a hidden plain text field, never a page.
    function copyText(text) {
        copyHelper.text = text
        copyHelper.selectAll()
        copyHelper.copy()
        copyHelper.text = ""
        panel.copied = true
        copiedTimer.restart()
    }

    function remove(entry) {
        panel.confirmingRemove = 0
        if (entry.id > 0)
            panel.removeRequested(entry.id)
        else
            panel.sessionRemoveRequested(entry.id)
    }

    function keep(kind) {
        if (sessionInput.text.trim() === "")
            return
        panel.sessionAddRequested(kind, sessionInput.text)
        sessionInput.text = ""
    }

    function errorText(code) {
        switch (code) {
        case "":
            return ""
        case "busy":
            return i18n("The encrypted folder is busy. Try again in a moment.")
        case "full":
            return i18n("The library is full (at most 100 items).")
        case "too-long":
            return i18n("That text is too long.")
        case "not-text":
            return i18n("That isn't plain text.")
        case "missing-tool":
            return i18n("kdialog is missing. Install it to add prompts.")
        case "locked":
            return i18n("The encrypted folder is locked.")
        default:
            return i18n("Something went wrong with the prompt library.")
        }
    }

    Timer {
        id: copiedTimer
        interval: 4000
        onTriggered: panel.copied = false
    }

    // Never shown; holds a copied text only for the moment of the copy.
    TextEdit {
        id: copyHelper
        visible: false
        readOnly: true
        textFormat: TextEdit.PlainText
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            Layout.fillWidth: true
            level: 4
            textFormat: Text.PlainText
            text: i18n("Prompts")
        }
        PlasmaComponents.BusyIndicator {
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            visible: panel.busy || panel.libraryState === "loading"
            running: visible
        }
        PlasmaComponents.ToolButton {
            icon.name: "window-close"
            display: QQC2.AbstractButton.IconOnly
            text: i18n("Close")
            onClicked: panel.closeRequested()
            QQC2.ToolTip.text: text
            QQC2.ToolTip.visible: hovered
        }
    }

    PlasmaComponents.Label {
        objectName: "libraryNote"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        opacity: 0.72
        font: Kirigami.Theme.smallFont
        text: panel.saved
            ? i18n("Saved in the encrypted folder.")
            : panel.encryptedMode
            ? i18n("Kept for this session only. Unlock the encrypted folder in a web chat to see and save your saved prompts.")
            : i18n("Kept for this session only. To save prompts, turn on Stay signed in → Encrypted in the settings.")
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        visible: text !== ""
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Kirigami.Theme.negativeTextColor
        text: panel.errorText(panel.error)
    }

    PlasmaComponents.Label {
        objectName: "copiedNote"
        Layout.fillWidth: true
        visible: panel.copied
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        color: Kirigami.Theme.positiveTextColor
        text: i18n("Copied — paste with Ctrl+V.")
    }

    QQC2.ScrollView {
        id: entriesScroll
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(entries.implicitHeight, Kirigami.Units.gridUnit * 10)
        visible: panel.items.length > 0
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        clip: true

        ColumnLayout {
            id: entries
            width: entriesScroll.availableWidth
            spacing: 0

            Repeater {
                model: panel.prompts.concat(panel.personas)

                delegate: ColumnLayout {
                    id: entry
                    required property var modelData
                    readonly property bool persona: entry.modelData.kind === "persona"
                    Layout.fillWidth: true
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            source: entry.persona ? "user-identity" : "text-plain"
                        }
                        PlasmaComponents.Label {
                            objectName: "libraryItemText"
                            Layout.fillWidth: true
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            text: PromptLibrary.label(entry.modelData.text)
                        }
                        PlasmaComponents.ToolButton {
                            objectName: "libraryUseButton"
                            icon.name: panel.forOllama ? (entry.persona ? "user-identity" : "edit-paste") : "edit-copy"
                            display: QQC2.AbstractButton.IconOnly
                            text: !panel.forOllama ? i18n("Copy")
                                : entry.persona ? i18n("Use as personality") : i18n("Insert into message")
                            onClicked: {
                                if (!panel.forOllama)
                                    panel.copyText(entry.modelData.text)
                                else if (entry.persona)
                                    panel.personaRequested(entry.modelData)
                                else
                                    panel.useRequested(entry.modelData.text)
                            }
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                        }
                        PlasmaComponents.ToolButton {
                            icon.name: "document-edit"
                            display: QQC2.AbstractButton.IconOnly
                            visible: entry.modelData.id > 0
                            enabled: !panel.busy
                            text: i18n("Replace…")
                            onClicked: panel.replaceRequested(entry.modelData.id)
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                        }
                        PlasmaComponents.ToolButton {
                            objectName: "libraryRemoveButton"
                            icon.name: "edit-delete"
                            display: QQC2.AbstractButton.IconOnly
                            enabled: !panel.busy
                            text: i18n("Remove")
                            onClicked: panel.confirmingRemove = entry.modelData.id
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                        }
                    }
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: panel.confirmingRemove !== 0 && panel.confirmingRemove === entry.modelData.id
                        type: Kirigami.MessageType.Warning
                        text: i18n("Remove this item?")
                        actions: [
                            Kirigami.Action {
                                text: i18n("Remove")
                                icon.name: "edit-delete"
                                onTriggered: panel.remove(entry.modelData)
                            },
                            Kirigami.Action {
                                text: i18n("Cancel")
                                icon.name: "dialog-cancel"
                                onTriggered: panel.confirmingRemove = 0
                            }
                        ]
                    }
                }
            }
        }
    }

    // Saved items are typed in KDE's own text window (kdialog), run by the
    // helper; the text never passes through the command line.
    RowLayout {
        Layout.fillWidth: true
        visible: panel.saved
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Button {
            icon.name: "list-add"
            enabled: !panel.busy
            text: i18n("New prompt…")
            onClicked: panel.addRequested("prompt")
        }
        PlasmaComponents.Button {
            icon.name: "list-add-user"
            enabled: !panel.busy
            text: i18n("New personality…")
            onClicked: panel.addRequested("persona")
        }
    }

    // Not saved: typed here, kept in memory for this session only.
    QQC2.ScrollView {
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 3
        visible: !panel.saved
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        clip: true

        PlasmaComponents.TextArea {
            id: sessionInput
            objectName: "sessionLibraryInput"
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            Kirigami.SpellCheck.enabled: false
            inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
            placeholderText: i18n("A prompt or personality to keep for this session")
            Accessible.name: i18n("New prompt")
        }
    }
    RowLayout {
        Layout.fillWidth: true
        visible: !panel.saved
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Button {
            objectName: "keepPromptButton"
            icon.name: "list-add"
            enabled: sessionInput.text.trim() !== ""
                && sessionInput.text.length <= PromptLibrary.MAX_CHARS.prompt
            text: i18n("Keep as prompt")
            onClicked: panel.keep("prompt")
        }
        PlasmaComponents.Button {
            icon.name: "list-add-user"
            enabled: sessionInput.text.trim() !== ""
                && sessionInput.text.length <= PromptLibrary.MAX_CHARS.persona
            text: i18n("Keep as personality")
            onClicked: panel.keep("persona")
        }
    }
}
