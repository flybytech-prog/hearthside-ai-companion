import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami
import "OllamaChat.js" as OllamaChat
import "ChatStorage.js" as ChatStorage

// Built-in chat with the Ollama server on this computer. Prompts and replies
// live only in this view's memory (the transcript model below) and in the
// request body sent over loopback; nothing is saved, logged or handed to the
// helper. The helper only answers who owns the port, checked before the
// model list is loaded and before every request.
//
// Everything the server sends is untrusted: it is reduced by OllamaChat.js
// and shown as plain text only.
ColumnLayout {
    id: ollamaView

    // True while Ollama is shown in the open popup. Nothing is contacted
    // before that.
    property bool current: false
    // "ollama" is enabled in the settings; turning it off clears everything.
    property bool siteEnabled: false
    // Already validated by main.qml (OllamaChat.effectiveAddress).
    property string address: OllamaChat.DEFAULT_ADDRESS
    // appletId only makes the helper's source name unique. createRequest and
    // runOwnerCheck are test seams: overridden by tests only, never in the
    // plasmoid.
    property int appletId: 0
    property var createRequest: function () { return new XMLHttpRequest() }
    property var runOwnerCheck: function (command) { ownerSource.connectSource(command) }

    // Timeouts in ms. Loading a big model on a CPU can take minutes.
    property int firstByteTimeout: 300000
    property int idleTimeout: 120000
    property int probeTimeout: 15000
    property int ownerTimeout: 15000
    // While a reply streams it is read and shown at most this often: each
    // read decodes the whole body again, each refresh lays out the last
    // paragraph again. 0 = every chunk.
    property int renderInterval: 100

    // Installed local chat models, runtime only: [{name, parameterSize, family}]
    property var modelList: []
    property int hiddenRemote: 0
    property string modelName: ""
    // idle (not loaded), loading, ready, failed
    property string listState: "idle"
    // Message code shown above the input; "" when there is none.
    property string problem: ""
    // A server's own error text, already made safe by OllamaChat.
    property string problemDetail: ""
    // Owner check in flight for: "", load, send, unload
    property string checking: ""
    property string ownerSourceName: ""
    // See ChatStorage.firstRun.
    property int ownerRun: ChatStorage.firstRun(Date.now(), Math.random())
    property bool generating: false
    property bool confirmingClear: false
    // Bumped whenever a request is dropped; late events of older ones are ignored.
    property int requestToken: 0
    property var request: null
    property var stream: OllamaChat.newStream()
    property int replyRow: -1
    property string pendingPrompt: ""
    // Models used in this conversation; unloaded on Clear.
    property var usedModels: []
    property var unloadNames: []
    // Change handlers wait for this: they also run while the view is built.
    property bool completed: false

    property alias messages: transcript
    readonly property int port: OllamaChat.portOf(ollamaView.address)
    readonly property int modelIndex: ollamaView.modelList.map(function (entry) {
        return entry.name
    }).indexOf(ollamaView.modelName)
    readonly property bool promptTooLong: input.text.length > OllamaChat.MAX_PROMPT_CHARS
    readonly property bool busy: ollamaView.generating || ollamaView.checking !== ""
        || ollamaView.listState === "loading"
    readonly property bool canSend: ollamaView.current && ollamaView.siteEnabled
        && ollamaView.listState === "ready" && ollamaView.modelName !== ""
        && !ollamaView.generating && ollamaView.checking === ""
        && input.text.trim() !== "" && !ollamaView.promptTooLong
    readonly property bool hasConversation: transcript.count > 0 || ollamaView.generating

    spacing: 0

    function focusInput() {
        if (ollamaView.current)
            input.forceActiveFocus()
    }

    function focusLater() {
        Qt.callLater(ollamaView.focusInput)
    }

    function selectModel(name) {
        if (ollamaView.modelList.some(function (entry) { return entry.name === name }))
            ollamaView.modelName = name
    }

    function reloadModels() {
        if (!ollamaView.busy)
            ollamaView.load()
    }

    // --- requests -----------------------------------------------------------

    // Forgets the request in flight without touching it.
    function settle() {
        ollamaView.requestToken += 1
        ollamaView.request = null
        readTimer.stop()
        probeTimer.stop()
        firstByteTimer.stop()
        idleTimer.stop()
    }

    // abort() throws in Qt 6.12 even though it aborts; its events arrive
    // with an old token and are ignored.
    function dropRequest() {
        var xhr = ollamaView.request
        ollamaView.settle()
        if (xhr) {
            try {
                xhr.abort()
            } catch (error) {
            }
        }
    }

    function fetch(name, done) {
        ollamaView.dropRequest()
        if (OllamaChat.endpoint(ollamaView.address, name) === "") {
            ollamaView.loadFailed("not-ollama")
            return
        }
        var token = ollamaView.requestToken
        var url = OllamaChat.endpoint(ollamaView.address, name)
        var xhr = ollamaView.createRequest()
        ollamaView.request = xhr
        xhr.onreadystatechange = function () {
            if (token !== ollamaView.requestToken || xhr.readyState < 3)
                return
            if (!ollamaView.answeredAt(xhr, url)) {
                ollamaView.dropRequest()
                ollamaView.loadFailed("not-ollama")
                return
            }
            if (xhr.readyState !== 4)
                return
            ollamaView.settle()
            done(xhr.status, xhr.responseText)
        }
        xhr.open("GET", OllamaChat.endpoint(ollamaView.address, name))
        xhr.send()
        probeTimer.restart()
    }

    // Qt follows redirects (and sends a POST body again) without showing
    // them; from readyState 3 on, responseURL is the address that answered.
    // A reply from anywhere but the checked endpoint is never read.
    function answeredAt(xhr, url) {
        return typeof xhr.responseURL === "string" && url !== "" && xhr.responseURL === url
    }

    // Owner check → GET /api/version → GET /api/tags. A pending unload check
    // reloads the list itself when it ends.
    function load() {
        if (!ollamaView.current || !ollamaView.siteEnabled || ollamaView.generating
                || ollamaView.checking === "send" || ollamaView.checking === "unload"
                || ollamaView.listState === "loading")
            return
        ollamaView.dropRequest()
        ollamaView.listState = "loading"
        ollamaView.problem = ""
        ollamaView.problemDetail = ""
        ollamaView.checkOwner("load")
    }

    // A failed GET: only a JSON reply from /api/version counts as Ollama.
    function getFailure(status) {
        var failure = OllamaChat.classifyFailure(status)
        return failure === "not-running" || failure === "forbidden" || failure === "server-error"
            ? failure : "not-ollama"
    }

    function probeVersion() {
        ollamaView.fetch("version", function (status, text) {
            if (status !== 200) {
                ollamaView.loadFailed(ollamaView.getFailure(status))
                return
            }
            if (!OllamaChat.parseVersion(status, text).ok) {
                ollamaView.loadFailed("not-ollama")
                return
            }
            ollamaView.listModels()
        })
    }

    function listModels() {
        ollamaView.fetch("tags", function (status, text) {
            var tags = OllamaChat.parseTags(status, text)
            if (!tags.ok) {
                ollamaView.loadFailed(status === 200 ? "not-ollama" : ollamaView.getFailure(status))
                return
            }
            ollamaView.modelList = tags.models
            ollamaView.hiddenRemote = tags.hiddenRemote
            ollamaView.modelName = OllamaChat.pickModel(tags.models, ollamaView.modelName)
            ollamaView.listState = "ready"
            ollamaView.problem = tags.models.length === 0 ? "no-models" : ""
            ollamaView.problemDetail = ""
        })
    }

    function loadFailed(code) {
        ollamaView.listState = "failed"
        ollamaView.modelList = []
        ollamaView.hiddenRemote = 0
        ollamaView.problem = code
        ollamaView.problemDetail = ""
    }

    // --- port owner check ---------------------------------------------------

    function checkOwner(purpose) {
        ollamaView.cancelOwnerCheck()
        ollamaView.ownerRun = ChatStorage.nextRun(ollamaView.ownerRun)
        // From the address itself: in onAddressChanged the port binding
        // may still hold the old port.
        var command = OllamaChat.ownerCommand(OllamaChat.portOf(ollamaView.address), ollamaView.ownerRun,
            Math.max(0, ChatStorage.validInt(ollamaView.appletId)))
        if (command === "") {
            ollamaView.afterOwnerCheck(purpose, "owner-unknown")
            return
        }
        ollamaView.checking = purpose
        ollamaView.ownerSourceName = command
        checkTimer.interval = ollamaView.ownerTimeout
        checkTimer.restart()
        ollamaView.runOwnerCheck(command)
    }

    function endOwnerCheck() {
        checkTimer.stop()
        ollamaView.ownerSourceName = ""
        ollamaView.checking = ""
    }

    function cancelOwnerCheck() {
        if (ollamaView.ownerSourceName !== "")
            ownerSource.disconnectSource(ollamaView.ownerSourceName)
        var purpose = ollamaView.checking
        ollamaView.endOwnerCheck()
        if (purpose === "load")
            ollamaView.listState = "idle"
        else if (purpose === "send")
            ollamaView.pendingPrompt = ""
        else if (purpose === "unload")
            ollamaView.unloadNames = []
    }

    // Fails closed: anything but a clear self/system answer stops here.
    function ownerProblem(reply) {
        if (!reply || reply.ok !== true)
            return "owner-unknown"
        if (reply.owner === "none")
            return "not-running"
        if (reply.owner === "other")
            return "other"
        return OllamaChat.trusted(reply.owner) ? "" : "owner-unknown"
    }

    // The helper's reply, already parsed by OllamaChat.parseOwnerReply.
    function ownerDone(source, reply) {
        if (ollamaView.checking === "" || source !== ollamaView.ownerSourceName)
            return
        var purpose = ollamaView.checking
        ollamaView.endOwnerCheck()
        ollamaView.afterOwnerCheck(purpose, ollamaView.ownerProblem(reply))
    }

    function afterOwnerCheck(purpose, problem) {
        switch (purpose) {
        case "load":
            if (problem !== "")
                ollamaView.loadFailed(problem)
            else
                ollamaView.probeVersion()
            break
        case "send":
            if (problem !== "") {
                // The prompt stays in the input.
                ollamaView.pendingPrompt = ""
                ollamaView.loadFailed(problem)
            } else {
                ollamaView.startChat()
            }
            break
        case "unload":
            var names = ollamaView.unloadNames
            ollamaView.unloadNames = []
            if (problem === "")
                ollamaView.unloadModels(names)
            if (ollamaView.listState === "idle" || ollamaView.listState === "failed")
                ollamaView.load()
            break
        }
    }

    // --- chat -----------------------------------------------------------------

    function historyWith(prompt) {
        var history = []
        for (var index = 0; index < transcript.count; index++) {
            var row = transcript.get(index)
            if (row.body !== "")
                history.push({ role: row.author, content: row.body })
        }
        history.push({ role: "user", content: prompt })
        return history
    }

    function send() {
        if (!ollamaView.canSend)
            return
        ollamaView.pendingPrompt = input.text
        ollamaView.problem = ""
        ollamaView.problemDetail = ""
        ollamaView.checkOwner("send")
    }

    function startChat() {
        var prompt = ollamaView.pendingPrompt
        ollamaView.pendingPrompt = ""
        var name = ollamaView.modelName
        var body = OllamaChat.chatRequestBody(name, ollamaView.historyWith(prompt))
        if (body === "" || OllamaChat.endpoint(ollamaView.address, "chat") === "") {
            ollamaView.problem = "not-sent"
            return
        }
        input.text = ""
        transcript.append({ author: "user", body: prompt, phase: "done" })
        transcript.append({ author: "assistant", body: "", phase: "waiting" })
        ollamaView.replyRow = transcript.count - 1
        if (ollamaView.usedModels.indexOf(name) < 0)
            ollamaView.usedModels = ollamaView.usedModels.concat([name])
        ollamaView.generating = true
        ollamaView.stream = OllamaChat.newStream()
        ollamaView.dropRequest()
        var token = ollamaView.requestToken
        var url = OllamaChat.endpoint(ollamaView.address, "chat")
        var xhr = ollamaView.createRequest()
        ollamaView.request = xhr
        xhr.onreadystatechange = function () {
            if (token !== ollamaView.requestToken)
                return
            if (xhr.readyState === 3 || xhr.readyState === 4)
                ollamaView.chatProgress(xhr, url, xhr.readyState === 4)
        }
        xhr.open("POST", OllamaChat.endpoint(ollamaView.address, "chat"))
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body)
        firstByteTimer.interval = ollamaView.firstByteTimeout
        firstByteTimer.restart()
        Qt.callLater(transcriptView.positionViewAtEnd)
    }

    function chatProgress(xhr, url, finished) {
        if (!ollamaView.answeredAt(xhr, url)) {
            // Redirected: nothing from there is read or shown.
            ollamaView.dropRequest()
            ollamaView.stream = OllamaChat.newStream()
            ollamaView.finishChat("failed", "server-error", "")
            return
        }
        var status = xhr.status
        if (status !== 200) {
            // Wait for the whole error reply.
            if (!finished)
                return
            var failure = OllamaChat.classifyFailure(status)
            var detail = ""
            if (failure === "server-error" || failure === "unexpected") {
                var parsed = OllamaChat.feedStream(OllamaChat.newStream(), xhr.responseText, true)
                detail = parsed.error === "server" ? parsed.errorText : ""
                failure = "server-error"
            }
            ollamaView.finishChat("failed", failure, detail)
            return
        }
        firstByteTimer.stop()
        if (!finished) {
            idleTimer.interval = ollamaView.idleTimeout
            idleTimer.restart()
            if (ollamaView.renderInterval > 0) {
                if (!readTimer.running)
                    readTimer.start()
                return
            }
        }
        ollamaView.readReply(xhr, finished)
    }

    // Reads what has arrived of the reply (already checked by chatProgress)
    // and puts it on screen.
    function readReply(xhr, finished) {
        readTimer.stop()
        var next = OllamaChat.feedStream(ollamaView.stream, xhr.responseText, finished)
        ollamaView.stream = next
        if (next.error === "too-long") {
            ollamaView.dropRequest()
            ollamaView.finishChat("cut", "", "")
        } else if (next.error === "server") {
            ollamaView.finishChat("failed", "server-error", next.errorText)
        } else if (next.error !== "") {
            ollamaView.finishChat("failed", "server-error", "")
        } else if (next.done) {
            ollamaView.finishChat("done", "", "")
        } else if (finished) {
            // The connection ended without "done".
            ollamaView.finishChat("failed", "timeout", "")
        } else {
            ollamaView.render()
        }
    }

    // Puts the reply read so far on screen.
    function render() {
        var row = ollamaView.replyRow
        if (row < 0 || row >= transcript.count)
            return
        var next = ollamaView.stream
        var phase = next.content !== "" ? "streaming" : next.thinking ? "thinking" : "waiting"
        var follow = transcriptView.atYEnd
        if (transcript.get(row).body !== next.content)
            transcript.setProperty(row, "body", next.content)
        if (transcript.get(row).phase !== phase)
            transcript.setProperty(row, "phase", phase)
        if (follow)
            Qt.callLater(transcriptView.positionViewAtEnd)
    }

    // Reply text as shown: paragraphs and code blocks, so that while a
    // reply streams only its last block is laid out again. Hidden direction
    // and zero-width characters are shown as markers (OllamaChat.revealHidden),
    // so what is shown, selected and copied is the same text.
    function blocks(text) {
        var result = []
        var parts = OllamaChat.segments(text)
        for (var index = 0; index < parts.length; index++) {
            if (parts[index].kind === "code") {
                result.push({ kind: "code", text: OllamaChat.revealHidden(parts[index].text),
                              lang: parts[index].lang })
                continue
            }
            var paragraphs = parts[index].text.split(/\n(?:[ \t]*\n)+/)
            for (var inner = 0; inner < paragraphs.length; inner++) {
                var paragraph = paragraphs[inner].replace(/^(?:[ \t]*\n)+|(?:\n[ \t]*)+$/g, "")
                if (paragraph.trim() !== "")
                    result.push({ kind: "text", text: OllamaChat.revealHidden(paragraph), lang: "" })
            }
        }
        return result
    }

    // phase of the reply row: done, stopped, cut, failed. An empty reply
    // that didn't finish is removed; the user's message stays.
    function finishChat(phase, problem, detail) {
        ollamaView.render()
        ollamaView.settle()
        ollamaView.generating = false
        ollamaView.stream = OllamaChat.newStream()
        var row = ollamaView.replyRow
        ollamaView.replyRow = -1
        if (row >= 0 && row < transcript.count) {
            if (transcript.get(row).body === "" && phase !== "done")
                transcript.remove(row)
            else
                transcript.setProperty(row, "phase", phase)
        }
        ollamaView.problem = problem
        ollamaView.problemDetail = detail
        if (problem === "not-running" || problem === "forbidden")
            ollamaView.listState = "failed"
        ollamaView.focusLater()
    }

    // Send turns into Stop while a reply is coming; Esc does the same.
    function stop() {
        if (ollamaView.checking === "send") {
            ollamaView.cancelOwnerCheck()
            return
        }
        // What arrived since the last read is shown too.
        if (readTimer.running && ollamaView.request)
            ollamaView.readReply(ollamaView.request, false)
        if (!ollamaView.generating)
            return
        ollamaView.dropRequest()
        ollamaView.finishChat("stopped", "", "")
    }

    // Drops the conversation from memory. With unload, Ollama is also asked
    // to unload the models used (keep_alive 0), which drops its cache of
    // the conversation; that request carries no prompt.
    function clearConversation(unload) {
        ollamaView.confirmingClear = false
        var names = ollamaView.usedModels
        ollamaView.cancelOwnerCheck()
        ollamaView.dropRequest()
        ollamaView.generating = false
        ollamaView.pendingPrompt = ""
        ollamaView.stream = OllamaChat.newStream()
        ollamaView.replyRow = -1
        ollamaView.usedModels = []
        transcript.clear()
        input.text = ""
        if (ollamaView.listState === "ready") {
            ollamaView.problem = ollamaView.modelList.length === 0 ? "no-models" : ""
            ollamaView.problemDetail = ""
        }
        gc()
        if (unload && names.length > 0 && ollamaView.current && ollamaView.siteEnabled) {
            ollamaView.unloadNames = names
            ollamaView.checkOwner("unload")
        } else if (ollamaView.listState === "idle") {
            ollamaView.load()
        }
        ollamaView.focusLater()
    }

    function unloadModels(names) {
        for (var index = 0; index < names.length; index++) {
            var body = OllamaChat.unloadRequestBody(names[index])
            if (body === "" || OllamaChat.endpoint(ollamaView.address, "chat") === "")
                continue
            // Fire and forget; the reply is never read.
            var xhr = ollamaView.createRequest()
            xhr.open("POST", OllamaChat.endpoint(ollamaView.address, "chat"))
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(body)
        }
    }

    // Word wrapping a long run without spaces gets very slow (quadratic in
    // Qt's text layout); such text wraps anywhere instead.
    function wrapFor(text) {
        return /\S{120}/.test(text) ? TextEdit.WrapAnywhere : TextEdit.Wrap
    }

    // A user-chosen text, copied through a hidden plain text field.
    function copyText(text) {
        copyHelper.text = text
        copyHelper.selectAll()
        copyHelper.copy()
        copyHelper.text = ""
    }

    // Fixed texts only; the address is never shown, only its port.
    function problemText(code) {
        switch (code) {
        case "":
            return ""
        case "not-running":
            return i18n("Ollama isn't running.")
        case "other":
            return i18n("Another user's program is using port %1. Hearthside won't send anything to it.", ollamaView.port)
        case "owner-unknown":
            return i18n("Couldn't check which program is using port %1.", ollamaView.port)
        case "not-ollama":
            return i18n("Something other than Ollama is answering at this address.")
        case "forbidden":
            return i18n("Ollama refused the request.")
        case "no-models":
            return i18n("No models installed. In a terminal run:")
        case "model-missing":
            return i18n("This model isn't installed any more.")
        case "timeout":
            return i18n("Ollama stopped responding.")
        case "not-sent":
            return i18n("Couldn't send this message.")
        default:
            return i18n("Ollama reported an error.")
        }
    }

    function problemHint(code) {
        switch (code) {
        case "not-running":
            return "systemctl start ollama   (or run: ollama serve)"
        case "no-models":
            return "ollama pull llama3"
        default:
            return ""
        }
    }

    onCurrentChanged: {
        if (!ollamaView.completed || !ollamaView.current)
            return
        if (ollamaView.listState === "idle" || ollamaView.listState === "failed")
            ollamaView.load()
        ollamaView.focusLater()
    }
    onSiteEnabledChanged: {
        if (!ollamaView.completed)
            return
        if (ollamaView.siteEnabled) {
            if (ollamaView.current)
                ollamaView.load()
            return
        }
        ollamaView.clearConversation(false)
        ollamaView.cancelOwnerCheck()
        ollamaView.listState = "idle"
        ollamaView.modelList = []
        ollamaView.hiddenRemote = 0
        ollamaView.problem = ""
        ollamaView.problemDetail = ""
    }
    // A new address: the old model list and any reply in flight belong to
    // the old server. The conversation stays.
    onAddressChanged: {
        if (!ollamaView.completed)
            return
        if (ollamaView.generating)
            ollamaView.stop()
        ollamaView.cancelOwnerCheck()
        ollamaView.dropRequest()
        ollamaView.listState = "idle"
        ollamaView.modelList = []
        ollamaView.hiddenRemote = 0
        ollamaView.problem = ""
        ollamaView.problemDetail = ""
        if (ollamaView.current)
            ollamaView.load()
    }

    // The popup may be created with Ollama already shown.
    Component.onCompleted: {
        ollamaView.completed = true
        if (ollamaView.current) {
            ollamaView.load()
            ollamaView.focusLater()
        }
    }

    // Accepted, so Esc stops a reply without closing the popup; otherwise it
    // passes on as usual.
    Keys.onEscapePressed: (event) => {
        if (ollamaView.generating || ollamaView.checking === "send") {
            ollamaView.stop()
            event.accepted = true
        } else {
            event.accepted = false
        }
    }

    ListModel {
        id: transcript
    }

    Plasma5Support.DataSource {
        id: ownerSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            ownerSource.disconnectSource(source)
            // Only stdout's known words are used.
            ollamaView.ownerDone(source, OllamaChat.parseOwnerReply(data["exit code"], data["stdout"]))
        }
    }

    Timer {
        id: readTimer
        interval: ollamaView.renderInterval
        repeat: false
        onTriggered: {
            if (ollamaView.request)
                ollamaView.readReply(ollamaView.request, false)
        }
    }

    Timer {
        id: checkTimer
        repeat: false
        onTriggered: {
            var purpose = ollamaView.checking
            ollamaView.cancelOwnerCheck()
            ollamaView.afterOwnerCheck(purpose, "owner-unknown")
        }
    }

    Timer {
        id: probeTimer
        interval: ollamaView.probeTimeout
        repeat: false
        onTriggered: {
            ollamaView.dropRequest()
            ollamaView.loadFailed("timeout")
        }
    }

    Timer {
        id: firstByteTimer
        repeat: false
        onTriggered: {
            ollamaView.dropRequest()
            ollamaView.finishChat("failed", "timeout", "")
        }
    }

    Timer {
        id: idleTimer
        repeat: false
        onTriggered: {
            ollamaView.dropRequest()
            ollamaView.finishChat("failed", "timeout", "")
        }
    }

    // Never shown; holds a copied text only for the moment of the copy.
    TextEdit {
        id: copyHelper
        visible: false
        readOnly: true
        textFormat: TextEdit.PlainText
    }

    Kirigami.InlineMessage {
        objectName: "clearConfirm"
        Layout.fillWidth: true
        visible: ollamaView.confirmingClear
        type: Kirigami.MessageType.Warning
        text: i18n("Clear this conversation?")
        actions: [
            Kirigami.Action {
                text: i18n("Clear")
                icon.name: "edit-clear-history"
                onTriggered: ollamaView.clearConversation(true)
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: ollamaView.confirmingClear = false
            }
        ]
    }

    Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        QQC2.ScrollView {
            anchors.fill: parent
            // Text wraps; the side margins made the content a few pixels wider
            // than the view, which showed a stray horizontal scroll bar.
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ListView {
                id: transcriptView
                objectName: "transcript"
                model: transcript
                spacing: Kirigami.Units.largeSpacing
                topMargin: Kirigami.Units.largeSpacing
                bottomMargin: Kirigami.Units.largeSpacing
                leftMargin: Kirigami.Units.largeSpacing
                rightMargin: Kirigami.Units.largeSpacing
                reuseItems: false

                delegate: ColumnLayout {
                    id: message
                    required property int index
                    required property string author
                    required property string body
                    required property string phase
                    readonly property bool mine: message.author === "user"
                    // Text widths are set directly, never from a layout pass:
                    // wrapping long text at width 0 first would stall.
                    readonly property real textWidth: Math.max(Kirigami.Units.gridUnit * 10, message.width)

                    width: ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
                    spacing: Kirigami.Units.smallSpacing

                    // Updates the reply's blocks in place: unchanged blocks
                    // keep their item and layout while the reply grows.
                    function syncBlocks() {
                        var wanted = message.mine ? [] : ollamaView.blocks(message.body)
                        for (var index = 0; index < wanted.length; index++) {
                            if (index >= blockModel.count) {
                                blockModel.append({ kind: wanted[index].kind, content: wanted[index].text })
                                continue
                            }
                            var shown = blockModel.get(index)
                            if (shown.kind !== wanted[index].kind)
                                blockModel.setProperty(index, "kind", wanted[index].kind)
                            if (shown.content !== wanted[index].text)
                                blockModel.setProperty(index, "content", wanted[index].text)
                        }
                        if (blockModel.count > wanted.length)
                            blockModel.remove(wanted.length, blockModel.count - wanted.length)
                    }

                    onBodyChanged: message.syncBlocks()
                    Component.onCompleted: message.syncBlocks()

                    ListModel {
                        id: blockModel
                    }

                    // The user's message, right-aligned in a tinted bubble.
                    Rectangle {
                        Layout.alignment: Qt.AlignRight
                        Layout.preferredWidth: userText.width + Kirigami.Units.largeSpacing * 2
                        Layout.preferredHeight: userText.height + Kirigami.Units.smallSpacing * 2
                        visible: message.mine
                        radius: Kirigami.Units.smallSpacing
                        color: Qt.alpha(Kirigami.Theme.highlightColor, 0.18)

                        TextEdit {
                            id: userText
                            x: Kirigami.Units.largeSpacing
                            y: Kirigami.Units.smallSpacing
                            width: Math.min(userText.implicitWidth,
                                Math.round(message.textWidth * 0.85) - Kirigami.Units.largeSpacing * 2)
                            readOnly: true
                            selectByMouse: true
                            wrapMode: ollamaView.wrapFor(message.body)
                            textFormat: TextEdit.PlainText
                            color: Kirigami.Theme.textColor
                            selectionColor: Kirigami.Theme.highlightColor
                            selectedTextColor: Kirigami.Theme.highlightedTextColor
                            font: Kirigami.Theme.defaultFont
                            text: message.mine ? message.body : ""
                        }
                    }

                    // The reply: plain text, fenced code blocks in monospace.
                    Repeater {
                        model: blockModel

                        delegate: Rectangle {
                            id: segment
                            required property string kind
                            required property string content
                            readonly property bool code: segment.kind === "code"
                            readonly property real padding: segment.code ? Kirigami.Units.smallSpacing : 0

                            Layout.fillWidth: true
                            Layout.preferredHeight: segmentText.height + segment.padding * 2
                            radius: Kirigami.Units.smallSpacing
                            color: segment.code
                                ? Kirigami.Theme.alternateBackgroundColor
                                : "transparent"

                            TextEdit {
                                id: segmentText
                                x: segment.padding
                                y: segment.padding
                                width: message.textWidth - segment.padding * 2 - (segment.code
                                    ? Kirigami.Units.iconSizes.medium + Kirigami.Units.smallSpacing : 0)
                                readOnly: true
                                selectByMouse: true
                                wrapMode: ollamaView.wrapFor(segment.content)
                                textFormat: TextEdit.PlainText
                                color: Kirigami.Theme.textColor
                                selectionColor: Kirigami.Theme.highlightColor
                                selectedTextColor: Kirigami.Theme.highlightedTextColor
                                font: segment.code ? Kirigami.Theme.fixedWidthFont : Kirigami.Theme.defaultFont
                                text: segment.content
                            }
                            PlasmaComponents.ToolButton {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                visible: segment.code
                                icon.name: "edit-copy"
                                display: QQC2.AbstractButton.IconOnly
                                text: i18n("Copy code")
                                onClicked: ollamaView.copyText(segment.content)
                                QQC2.ToolTip.text: text
                                QQC2.ToolTip.visible: hovered
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        objectName: "hiddenCharsNote"
                        Layout.fillWidth: true
                        visible: !message.mine && OllamaChat.hasHidden(message.body)
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: Kirigami.Theme.neutralTextColor
                        font: Kirigami.Theme.smallFont
                        text: i18n("This text contains hidden direction characters, shown as ⟦U+…⟧. Copy copies the marked text.")
                    }

                    RowLayout {
                        visible: !message.mine
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.BusyIndicator {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            visible: message.phase === "waiting" || message.phase === "thinking"
                            running: visible
                        }
                        PlasmaComponents.Label {
                            textFormat: Text.PlainText
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                            visible: text !== ""
                            text: {
                                switch (message.phase) {
                                case "thinking":
                                    return i18n("Thinking…")
                                case "stopped":
                                    return i18n("(stopped)")
                                case "cut":
                                    return i18n("Reply cut off (too long).")
                                case "failed":
                                    return i18n("(incomplete)")
                                default:
                                    return ""
                                }
                            }
                        }
                        PlasmaComponents.ToolButton {
                            visible: message.body !== "" && message.phase !== "waiting"
                                && message.phase !== "streaming" && message.phase !== "thinking"
                            icon.name: "edit-copy"
                            display: QQC2.AbstractButton.IconOnly
                            text: i18n("Copy reply")
                            // The marked text, as shown: hidden characters never
                            // reach the clipboard.
                            onClicked: ollamaView.copyText(OllamaChat.revealHidden(message.body))
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                        }
                    }
                }
            }
        }

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 22)
            visible: transcript.count === 0
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Kirigami.Units.iconSizes.huge
                Layout.preferredHeight: Kirigami.Units.iconSizes.huge
                source: Qt.resolvedUrl("../images/" + OllamaChat.ENTRY.icon)
                isMask: true
                color: Kirigami.Theme.textColor
                opacity: 0.5
            }
            PlasmaComponents.BusyIndicator {
                Layout.alignment: Qt.AlignHCenter
                visible: ollamaView.listState === "loading"
                running: visible
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                opacity: 0.72
                text: ollamaView.listState === "loading"
                    ? i18n("Connecting to Ollama…")
                    : i18n("Chat with a model on this computer. The conversation stays in memory only and is gone after Clear or a Plasma restart.")
            }
        }
    }

    // Status and errors, above the input.
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        visible: ollamaView.problem !== "" || ollamaView.promptTooLong
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            objectName: "problemText"
            Layout.fillWidth: true
            visible: ollamaView.problem !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: ollamaView.problem === "no-models"
                ? Kirigami.Theme.textColor : Kirigami.Theme.negativeTextColor
            text: ollamaView.problemText(ollamaView.problem)
        }
        QQC2.TextField {
            objectName: "problemHint"
            Layout.fillWidth: true
            visible: text !== ""
            readOnly: true
            selectByMouse: true
            font: Kirigami.Theme.fixedWidthFont
            text: ollamaView.problemHint(ollamaView.problem)
        }
        PlasmaComponents.Label {
            objectName: "problemDetail"
            Layout.fillWidth: true
            visible: ollamaView.problemDetail !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            opacity: 0.72
            text: ollamaView.problemDetail
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: ollamaView.problem === "no-models" && ollamaView.hiddenRemote > 0
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            opacity: 0.72
            text: i18n("Cloud models are hidden because they send your messages to ollama.com.")
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: ollamaView.promptTooLong
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: Kirigami.Theme.negativeTextColor
            text: i18n("This message is too long. A message can have at most %1 characters.",
                OllamaChat.MAX_PROMPT_CHARS)
        }
        PlasmaComponents.Button {
            objectName: "retryButton"
            visible: ollamaView.listState === "failed"
                || ollamaView.problem === "no-models" || ollamaView.problem === "model-missing"
            enabled: !ollamaView.busy
            icon.name: "view-refresh"
            text: ollamaView.listState === "failed" ? i18n("Retry") : i18n("Reload models")
            onClicked: ollamaView.load()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.maximumHeight: Kirigami.Units.gridUnit * 8
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            PlasmaComponents.TextArea {
                id: input
                objectName: "ollamaInput"
                // Locked only while the port is checked for this message.
                readOnly: ollamaView.checking === "send"
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                Kirigami.SpellCheck.enabled: false
                inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
                placeholderText: i18n("Message (Enter sends, Shift+Enter adds a line)")
                Accessible.name: i18n("Message to Ollama")
                Keys.onPressed: (event) => {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && !(event.modifiers & Qt.ShiftModifier)) {
                        event.accepted = true
                        ollamaView.send()
                    }
                }
            }
        }
        PlasmaComponents.Button {
            id: sendButton
            objectName: "sendButton"
            readonly property bool stopping: ollamaView.generating || ollamaView.checking === "send"
            Layout.alignment: Qt.AlignBottom
            enabled: sendButton.stopping || ollamaView.canSend
            icon.name: sendButton.stopping ? "media-playback-stop" : "document-send"
            text: sendButton.stopping ? i18n("Stop") : i18n("Send")
            onClicked: {
                if (sendButton.stopping)
                    ollamaView.stop()
                else
                    ollamaView.send()
            }
        }
    }
}
