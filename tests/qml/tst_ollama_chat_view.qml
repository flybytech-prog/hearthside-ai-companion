import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// OllamaChatView with a fake XMLHttpRequest (createRequest) and a fake port
// owner helper (runOwnerCheck). Nothing here opens a socket.
TestCase {
    id: testCase
    name: "OllamaChatView"
    width: 500
    height: 500
    visible: true
    when: windowShown

    // Plasma injects i18n(); a stand-in that fills %1.
    function i18n(text, arg) {
        return arg === undefined ? text : text.replace("%1", String(arg))
    }

    property var requests: []
    property var ownerCommands: []
    // What the fake helper answers; null leaves the check pending.
    property var ownerReply: ({ ok: true, owner: "system" })
    property int escapeAtParent: 0

    function newFake() {
        var fake = {
            readyState: 0,
            status: 0,
            responseText: "",
            // Like Qt: "" until readyState 3, then the address that answered.
            responseURL: "",
            // Set by a test: where the fake was redirected to.
            redirectedTo: "",
            method: "",
            url: "",
            headers: [],
            body: null,
            aborted: 0,
            onreadystatechange: null,
            open: function (method, url) {
                fake.method = method
                fake.url = url
                fake.readyState = 1
            },
            setRequestHeader: function (name, value) {
                fake.headers.push([name, value])
            },
            send: function (body) {
                fake.body = body === undefined ? null : body
                testCase.requests.push(fake)
            },
            // Like Qt 6.12: aborts, fires readyState 4, then throws.
            abort: function () {
                fake.aborted += 1
                fake.readyState = 4
                fake.status = 0
                fake.responseText = ""
                if (fake.onreadystatechange)
                    fake.onreadystatechange()
                throw new Error("Invalid state")
            },
            answered: function () {
                fake.responseURL = fake.redirectedTo !== "" ? fake.redirectedTo : fake.url
            },
            chunk: function (text) {
                fake.answered()
                fake.status = 200
                fake.readyState = 3
                fake.responseText += text
                if (fake.onreadystatechange)
                    fake.onreadystatechange()
            },
            finish: function (status, text) {
                fake.answered()
                fake.status = status
                fake.readyState = 4
                if (text !== undefined)
                    fake.responseText += text
                if (fake.onreadystatechange)
                    fake.onreadystatechange()
            }
        }
        return fake
    }

    function ownerAsked(view, command) {
        testCase.ownerCommands.push(command)
        if (testCase.ownerReply !== null)
            view.ownerDone(command, testCase.ownerReply)
    }

    Component {
        id: wrapperComponent
        FocusScope {
            id: wrapper
            property alias view: chat
            property bool shown: false
            property bool siteOn: true
            anchors.fill: parent
            Keys.onEscapePressed: testCase.escapeAtParent += 1

            OllamaChatView {
                id: chat
                anchors.fill: parent
                focus: true
                current: wrapper.shown
                siteEnabled: wrapper.siteOn
                appletId: 7
                // Every chunk on screen at once; test_renderIsThrottled covers the default.
                renderInterval: 0
                createRequest: function () { return testCase.newFake() }
                runOwnerCheck: function (command) { testCase.ownerAsked(chat, command) }
            }
        }
    }

    // Like the popup: a header with the tabs above the view.
    Component {
        id: headedComponent
        Column {
            id: headed
            property alias view: chat
            property alias header: tabs
            property bool shown: false
            anchors.fill: parent

            Rectangle {
                id: tabs
                width: parent.width
                height: 60
                color: "#ff00ff"
            }
            OllamaChatView {
                id: chat
                width: parent.width
                height: parent.height - tabs.height
                current: headed.shown
                siteEnabled: true
                appletId: 7
                renderInterval: 0
                createRequest: function () { return testCase.newFake() }
                runOwnerCheck: function (command) { testCase.ownerAsked(chat, command) }
            }
        }
    }

    function init() {
        testCase.requests = []
        testCase.ownerCommands = []
        testCase.ownerReply = { ok: true, owner: "system" }
        testCase.escapeAtParent = 0
    }

    function make(properties, component) {
        var wrapper = createTemporaryObject(component || wrapperComponent, testCase, properties || {})
        verify(wrapper !== null)
        return wrapper
    }

    function tags(models) {
        return JSON.stringify({ models: models })
    }

    property var defaultModels: [
        { name: "llama3:latest", details: { parameter_size: "8.0B", family: "llama" },
          capabilities: ["completion"] },
        { name: "qwen3:8b", capabilities: ["completion", "thinking"] },
        { name: "gpt-oss:120b-cloud", remote_host: "https://ollama.com:443" },
        { name: "nomic-embed-text:latest", capabilities: ["embedding"] }
    ]

    // Shown → owner check → version → tags, answered with models.
    function ready(models, component) {
        var wrapper = make({ shown: true }, component)
        var view = wrapper.view
        compare(testCase.requests.length, 1)
        compare(testCase.requests[0].url, "http://127.0.0.1:11434/api/version")
        testCase.requests[0].finish(200, "{\"version\":\"0.40.13\"}")
        compare(testCase.requests.length, 2)
        compare(testCase.requests[1].url, "http://127.0.0.1:11434/api/tags")
        testCase.requests[1].finish(200, tags(models === undefined ? testCase.defaultModels : models))
        return wrapper
    }

    function input(view) {
        var field = findChild(view, "ollamaInput")
        verify(field !== null)
        return field
    }

    // Types text and sends; returns the chat request.
    function sendText(view, text) {
        input(view).text = text
        verify(view.canSend)
        var before = testCase.requests.length
        view.send()
        compare(testCase.requests.length, before + 1)
        var request = testCase.requests[testCase.requests.length - 1]
        compare(request.method, "POST")
        compare(request.url, "http://127.0.0.1:11434/api/chat")
        return request
    }

    function line(object) {
        return JSON.stringify(object) + "\n"
    }

    function piece(content) {
        return line({ model: "llama3:latest", message: { role: "assistant", content: content }, done: false })
    }

    // --- when anything is contacted ------------------------------------------

    function test_nothingUntilShownAndEnabled() {
        var wrapper = make({ shown: false, siteOn: true })
        wait(30)
        compare(testCase.ownerCommands.length, 0)
        compare(testCase.requests.length, 0)
        wrapper.siteOn = false
        wrapper.shown = true
        wait(30)
        compare(testCase.ownerCommands.length, 0)
        compare(testCase.requests.length, 0)
        compare(wrapper.view.listState, "idle")
        wrapper.siteOn = true
        compare(testCase.ownerCommands.length, 1)
    }

    function test_loadOrderOwnerVersionTags() {
        testCase.ownerReply = null
        var wrapper = make({ shown: true })
        var view = wrapper.view
        compare(testCase.ownerCommands.length, 1)
        verify(/^env HEARTHSIDE_RUN=\d+ HEARTHSIDE_APPLET=7 python3 -P -m hearthside --port-owner 11434$/
               .test(testCase.ownerCommands[0]), testCase.ownerCommands[0])
        // Nothing goes to the port before the owner is known.
        compare(testCase.requests.length, 0)
        compare(view.listState, "loading")
        view.ownerDone(testCase.ownerCommands[0], { ok: true, owner: "self" })
        compare(testCase.requests.length, 1)
        compare(testCase.requests[0].method, "GET")
        compare(testCase.requests[0].url, "http://127.0.0.1:11434/api/version")
        compare(testCase.requests[0].body, null)
        testCase.requests[0].finish(200, "{\"version\":\"0.40.13\"}")
        compare(testCase.requests[1].method, "GET")
        compare(testCase.requests[1].url, "http://127.0.0.1:11434/api/tags")
        testCase.requests[1].finish(200, tags(testCase.defaultModels))
        compare(view.listState, "ready")
        compare(view.modelList.map(function (m) { return m.name }), ["llama3:latest", "qwen3:8b"])
        compare(view.hiddenRemote, 1)
        compare(view.modelName, "llama3:latest")
        compare(view.problem, "")
        // GETs carry no headers.
        compare(testCase.requests[0].headers.length, 0)
        compare(testCase.requests[1].headers.length, 0)
    }

    function test_lateOwnerReplyIsIgnored() {
        testCase.ownerReply = null
        var wrapper = make({ shown: true })
        var view = wrapper.view
        var first = testCase.ownerCommands[0]
        view.reloadModels()
        // Busy: no second check while one runs.
        compare(testCase.ownerCommands.length, 1)
        view.cancelOwnerCheck()
        view.load()
        compare(testCase.ownerCommands.length, 2)
        verify(testCase.ownerCommands[1] !== first)
        view.ownerDone(first, { ok: true, owner: "system" })
        compare(testCase.requests.length, 0)
        view.ownerDone(testCase.ownerCommands[1], { ok: true, owner: "system" })
        compare(testCase.requests.length, 1)
    }

    function test_untrustedOwnerBlocksEverything_data() {
        return [
            { tag: "none", reply: { ok: true, owner: "none" }, problem: "not-running" },
            { tag: "other", reply: { ok: true, owner: "other" }, problem: "other" },
            { tag: "unreadable", reply: { ok: false, error: "unreadable" }, problem: "owner-unknown" },
            { tag: "bad-reply", reply: { ok: false, error: "bad-reply" }, problem: "owner-unknown" },
            { tag: "odd-owner", reply: { ok: true, owner: "root" }, problem: "owner-unknown" },
            { tag: "null", reply: null, problem: "owner-unknown" }
        ]
    }

    function test_untrustedOwnerBlocksEverything(data) {
        testCase.ownerReply = null
        var wrapper = make({ shown: true })
        var view = wrapper.view
        view.ownerDone(testCase.ownerCommands[0], data.reply)
        compare(testCase.requests.length, 0)
        compare(view.listState, "failed")
        compare(view.problem, data.problem)
        input(view).text = "hello"
        verify(!view.canSend)
        view.send()
        compare(testCase.requests.length, 0)
        compare(findChild(view, "retryButton").visible, true)
        if (data.problem === "other" || data.problem === "owner-unknown")
            verify(findChild(view, "problemText").text.indexOf("port 11434") >= 0)
        if (data.problem === "not-running")
            compare(findChild(view, "problemHint").text, "systemctl start ollama   (or run: ollama serve)")
    }

    function test_ownerCheckTimesOutClosed() {
        testCase.ownerReply = null
        var wrapper = make({ shown: false })
        var view = wrapper.view
        view.ownerTimeout = 30
        wrapper.shown = true
        tryCompare(view, "problem", "owner-unknown")
        compare(view.listState, "failed")
        compare(testCase.requests.length, 0)
    }

    function test_retryAfterFailure() {
        testCase.ownerReply = { ok: true, owner: "none" }
        var wrapper = make({ shown: true })
        var view = wrapper.view
        compare(view.problem, "not-running")
        testCase.ownerReply = { ok: true, owner: "system" }
        findChild(view, "retryButton").clicked()
        compare(testCase.ownerCommands.length, 2)
        compare(testCase.requests.length, 1)
        compare(view.listState, "loading")
    }

    function test_notOllama_data() {
        return [
            { tag: "plain text", status: 200, text: "Ollama is running" },
            { tag: "html", status: 200, text: "<html><body>hi</body></html>" },
            { tag: "no version", status: 200, text: "{\"name\":\"x\"}" },
            { tag: "404", status: 404, text: "" }
        ]
    }

    function test_notOllama(data) {
        var wrapper = make({ shown: true })
        var view = wrapper.view
        testCase.requests[0].finish(data.status, data.text)
        compare(testCase.requests.length, 1)
        compare(view.problem, "not-ollama")
        compare(view.listState, "failed")
        verify(!view.canSend)
    }

    function test_versionConnectionRefused() {
        var wrapper = make({ shown: true })
        testCase.requests[0].finish(0, "")
        compare(wrapper.view.problem, "not-running")
    }

    function test_forbidden() {
        var wrapper = make({ shown: true })
        testCase.requests[0].finish(403, "")
        compare(wrapper.view.problem, "forbidden")
    }

    function test_noModels() {
        var wrapper = ready([{ name: "kimi:cloud" }, { name: "embed:latest", capabilities: ["embedding"] }])
        var view = wrapper.view
        compare(view.listState, "ready")
        compare(view.modelList.length, 0)
        compare(view.problem, "no-models")
        compare(view.hiddenRemote, 1)
        compare(findChild(view, "problemHint").text, "ollama pull llama3")
        input(view).text = "hello"
        verify(!view.canSend)
        compare(findChild(view, "retryButton").text, "Reload models")
    }

    function test_probeTimeout() {
        var wrapper = make({ shown: false })
        var view = wrapper.view
        view.probeTimeout = 30
        wrapper.shown = true
        compare(testCase.requests.length, 1)
        tryCompare(view, "problem", "timeout")
        compare(testCase.requests[0].aborted, 1)
        // A late answer of the dropped request changes nothing.
        testCase.requests[0].onreadystatechange()
        compare(testCase.requests.length, 1)
    }

    // Qt follows redirects without showing them; only responseURL tells.
    function test_redirectedLoadIsRefused_data() {
        return [
            { tag: "version, other port", step: 0, to: "http://127.0.0.1:9999/api/version" },
            { tag: "version, other host", step: 0, to: "http://localhost:11434/api/version" },
            { tag: "version, first chunk", step: 0, to: "http://127.0.0.1:9999/api/version", chunk: true },
            { tag: "tags, other port", step: 1, to: "http://127.0.0.1:9999/api/tags" },
            { tag: "tags, other path", step: 1, to: "http://127.0.0.1:11434/api/version" }
        ]
    }

    function test_redirectedLoadIsRefused(data) {
        var wrapper = make({ shown: true })
        var view = wrapper.view
        if (data.step === 1)
            testCase.requests[0].finish(200, "{\"version\":\"0.40.13\"}")
        var request = testCase.requests[data.step]
        request.redirectedTo = data.to
        var reply = data.step === 0 ? "{\"version\":\"0.40.13\"}" : tags(testCase.defaultModels)
        if (data.chunk)
            request.chunk(reply)
        else
            request.finish(200, reply)
        compare(request.aborted, 1)
        compare(testCase.requests.length, data.step + 1)
        compare(view.listState, "failed")
        compare(view.problem, "not-ollama")
        compare(view.modelList.length, 0)
        verify(!view.canSend)
        // Later events of the dropped request change nothing.
        request.finish(200, "")
        compare(testCase.requests.length, data.step + 1)
        compare(view.problem, "not-ollama")
    }

    // --- sending ----------------------------------------------------------------

    function test_sendStreamsAndKeepsHistory() {
        var wrapper = ready()
        var view = wrapper.view
        var checks = testCase.ownerCommands.length
        var request = sendText(view, "Hi <there>")
        // Every send checks the owner again first.
        compare(testCase.ownerCommands.length, checks + 1)
        compare(request.headers, [["Content-Type", "application/json"]])
        compare(JSON.parse(request.body), {
            model: "llama3:latest",
            messages: [{ role: "user", content: "Hi <there>" }],
            stream: true
        })
        compare(input(view).text, "")
        verify(view.generating)
        compare(view.messages.count, 2)
        compare(view.messages.get(0).author, "user")
        compare(view.messages.get(0).body, "Hi <there>")
        compare(view.messages.get(1).phase, "waiting")

        // A line split across chunks is read once it is complete.
        var first = piece("Hel")
        request.chunk(first.slice(0, 10))
        compare(view.messages.get(1).body, "")
        request.chunk(first.slice(10))
        compare(view.messages.get(1).body, "Hel")
        compare(view.messages.get(1).phase, "streaming")
        request.chunk(piece("lo é"))
        compare(view.messages.get(1).body, "Hello é")
        request.chunk(line({ done: true, done_reason: "stop", message: { role: "assistant", content: "" } }))
        verify(!view.generating)
        compare(view.messages.get(1).phase, "done")
        compare(view.problem, "")
        // Events after done are ignored.
        request.chunk(piece(" more"))
        compare(view.messages.get(1).body, "Hello é")

        var second = sendText(view, "And?")
        compare(JSON.parse(second.body).messages, [
            { role: "user", content: "Hi <there>" },
            { role: "assistant", content: "Hello é" },
            { role: "user", content: "And?" }
        ])
    }

    function test_sendBlockedByOwnerKeepsPrompt_data() {
        return [
            { tag: "none", reply: { ok: true, owner: "none" }, problem: "not-running" },
            { tag: "other", reply: { ok: true, owner: "other" }, problem: "other" },
            { tag: "error", reply: { ok: false, error: "unreadable" }, problem: "owner-unknown" }
        ]
    }

    function test_sendBlockedByOwnerKeepsPrompt(data) {
        var wrapper = ready()
        var view = wrapper.view
        var before = testCase.requests.length
        input(view).text = "secret question"
        testCase.ownerReply = data.reply
        view.send()
        compare(testCase.requests.length, before)
        compare(view.messages.count, 0)
        compare(input(view).text, "secret question")
        compare(view.problem, data.problem)
        verify(!view.canSend)
    }

    function test_inputLockedWhileSendCheckRuns() {
        var wrapper = ready()
        var view = wrapper.view
        testCase.ownerReply = null
        input(view).text = "question"
        view.send()
        compare(view.checking, "send")
        verify(input(view).readOnly)
        // Stop cancels the check; nothing was sent.
        view.stop()
        compare(view.checking, "")
        verify(!input(view).readOnly)
        compare(input(view).text, "question")
        compare(testCase.requests.length, 2)
    }

    function test_stopHandlesThrowingAbortAndLateEvents() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Tell me a story")
        request.chunk(piece("Once upon"))
        view.stop()
        compare(request.aborted, 1)
        verify(!view.generating)
        compare(view.messages.get(1).body, "Once upon")
        compare(view.messages.get(1).phase, "stopped")
        request.chunk(piece(" a time"))
        compare(view.messages.get(1).body, "Once upon")
        compare(view.problem, "")
        verify(!findChild(view, "sendButton").stopping)
    }

    function test_stopBeforeAnyTextDropsEmptyReply() {
        var wrapper = ready()
        var view = wrapper.view
        sendText(view, "Hi")
        view.stop()
        compare(view.messages.count, 1)
        compare(view.messages.get(0).author, "user")
    }

    function test_renderIsThrottled() {
        var wrapper = ready()
        var view = wrapper.view
        view.renderInterval = 40
        var request = sendText(view, "Hi")
        request.chunk(piece("One"))
        request.chunk(piece(" two"))
        compare(view.messages.get(1).body, "")
        tryCompare(view.messages.get(1), "body", "One two")
        // Stop shows what arrived, at once.
        request.chunk(piece(" three"))
        view.stop()
        compare(view.messages.get(1).body, "One two three")
        compare(view.messages.get(1).phase, "stopped")
    }

    // Each read decodes the whole body again: chunks only schedule one.
    function test_streamIsReadOnTheTimer() {
        var wrapper = ready()
        var view = wrapper.view
        view.renderInterval = 40
        var request = sendText(view, "Hi")
        request.chunk(piece("One"))
        request.chunk(piece(" two"))
        compare(view.stream.content, "")
        compare(view.stream.offset, 0)
        tryVerify(function () { return view.stream.content === "One two" })
        compare(view.messages.get(1).body, "One two")
        // The end is read at once.
        request.chunk(piece(" three"))
        request.finish(200, line({ done: true }))
        verify(!view.generating)
        compare(view.messages.get(1).body, "One two three")
        compare(view.messages.get(1).phase, "done")
        wait(60)
        compare(view.messages.get(1).body, "One two three")
    }

    function test_replyBlocks() {
        var view = make().view
        compare(JSON.stringify(view.blocks("Para one\nline\n\n  \nPara two\n```js\nx = 1\n\ny = 2\n```\ntail")), JSON.stringify([
            { kind: "text", text: "Para one\nline", lang: "" },
            { kind: "text", text: "Para two", lang: "" },
            { kind: "code", text: "x = 1\n\ny = 2", lang: "js" },
            { kind: "text", text: "tail", lang: "" }
        ]))
        compare(view.blocks(""), [])
        compare(view.wrapFor("short words only"), TextEdit.Wrap)
        compare(view.wrapFor(new Array(121).join("x")), TextEdit.WrapAnywhere)
    }

    function test_thinkingShowsOnlyTheState() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(line({ message: { role: "assistant", content: "", thinking: "secret plan" }, done: false }))
        compare(view.messages.get(1).phase, "thinking")
        compare(view.messages.get(1).body, "")
        request.chunk(piece("Answer"))
        compare(view.messages.get(1).phase, "streaming")
        compare(view.messages.get(1).body, "Answer")
    }

    function test_chatFailures_data() {
        return [
            { tag: "refused", status: 0, text: "", problem: "not-running", list: "failed" },
            { tag: "forbidden", status: 403, text: "", problem: "forbidden", list: "failed" },
            { tag: "missing", status: 404, text: "{\"error\":\"model 'x' not found\"}", problem: "model-missing",
              list: "ready" },
            { tag: "server", status: 500, text: "{\"error\":\"<b>out of memory</b>\"}", problem: "server-error",
              list: "ready", detail: "bout of memory/b" }
        ]
    }

    function test_chatFailures(data) {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.finish(data.status, data.text)
        verify(!view.generating)
        compare(view.problem, data.problem)
        compare(view.listState, data.list)
        compare(view.problemDetail, data.detail || "")
        // The empty reply is dropped, the question stays.
        compare(view.messages.count, 1)
    }

    function test_redirectedChatShowsNothing_data() {
        return [
            { tag: "chunk", interval: 0 },
            { tag: "chunk, throttled", interval: 40 },
            { tag: "finished", interval: 0, status: 200 },
            { tag: "error reply", interval: 0, status: 500 }
        ]
    }

    function test_redirectedChatShowsNothing(data) {
        var wrapper = ready()
        var view = wrapper.view
        view.renderInterval = data.interval
        var request = sendText(view, "Hi")
        request.redirectedTo = "http://127.0.0.1:9999/api/chat"
        if (data.status === undefined)
            request.chunk(piece("from elsewhere"))
        else if (data.status === 200)
            request.finish(200, piece("from elsewhere") + line({ done: true }))
        else
            request.finish(500, "{\"error\":\"from elsewhere\"}")
        compare(request.aborted, 1)
        verify(!view.generating)
        compare(view.problem, "server-error")
        compare(view.problemDetail, "")
        compare(view.stream.content, "")
        // Only the question stays.
        compare(view.messages.count, 1)
        compare(view.messages.get(0).author, "user")
        wait(60)
        request.chunk(piece(" more"))
        compare(view.messages.count, 1)
        compare(view.listState, "ready")
    }

    function test_serverErrorMarkupIsPlain() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(line({ error: "<img src=\"http://127.0.0.1:9/x\"> &amp; <b>bold</b>" }))
        compare(view.problem, "server-error")
        var label = findChild(view, "problemDetail")
        verify(label.visible)
        compare(label.textFormat, Text.PlainText)
        compare(label.text, view.problemDetail)
        verify(label.text.indexOf("bold") >= 0, label.text)
        verify(!/[<>&]/.test(label.text), label.text)
    }

    function test_serverErrorLineKeepsPartialReply() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(piece("Partial"))
        request.chunk(line({ error: "model runner stopped\u0007" }))
        verify(!view.generating)
        compare(view.messages.get(1).body, "Partial")
        compare(view.messages.get(1).phase, "failed")
        compare(view.problem, "server-error")
        compare(view.problemDetail, "model runner stopped")
    }

    function test_firstByteAndIdleTimeouts() {
        var wrapper = ready()
        var view = wrapper.view
        view.firstByteTimeout = 30
        var request = sendText(view, "Hi")
        tryCompare(view, "problem", "timeout")
        compare(request.aborted, 1)
        verify(!view.generating)

        view.firstByteTimeout = 100000
        view.idleTimeout = 30
        var next = sendText(view, "Again")
        next.chunk(piece("Part"))
        tryCompare(view, "problem", "timeout")
        compare(next.aborted, 1)
        compare(view.messages.get(view.messages.count - 1).body, "Part")
    }

    function test_replyTooLongIsCut() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(piece(new Array(200002).join("x")))
        verify(!view.generating)
        compare(request.aborted, 1)
        compare(view.messages.get(1).phase, "cut")
        compare(view.messages.get(1).body.length, 200000)
    }

    function test_promptTooLong() {
        var wrapper = ready()
        var view = wrapper.view
        input(view).text = new Array(32002).join("x")
        verify(view.promptTooLong)
        verify(!view.canSend)
        input(view).text = new Array(32001).join("x")
        verify(!view.promptTooLong)
        verify(view.canSend)
    }

    function test_modelChoiceIsKeptAcrossReload() {
        var wrapper = ready()
        var view = wrapper.view
        view.selectModel("qwen3:8b")
        compare(view.modelName, "qwen3:8b")
        view.selectModel("not-listed")
        compare(view.modelName, "qwen3:8b")
        view.reloadModels()
        testCase.requests[2].finish(200, "{\"version\":\"0.40.13\"}")
        testCase.requests[3].finish(200, tags(testCase.defaultModels))
        compare(view.modelName, "qwen3:8b")
        var request = sendText(view, "Hi")
        compare(JSON.parse(request.body).model, "qwen3:8b")
    }

    // --- clear ------------------------------------------------------------------

    function test_clearEmptiesAndUnloads() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(piece("Hello"))
        input(view).text = "draft"
        view.confirmingClear = true
        compare(findChild(view, "clearConfirm").visible, true)
        var before = testCase.requests.length
        var checks = testCase.ownerCommands.length
        view.clearConversation(true)
        compare(request.aborted, 1)
        compare(view.messages.count, 0)
        compare(input(view).text, "")
        verify(!view.generating)
        verify(!view.confirmingClear)
        compare(view.usedModels, [])
        // The unload request goes through the owner check and carries no prompt.
        compare(testCase.ownerCommands.length, checks + 1)
        compare(testCase.requests.length, before + 1)
        var unload = testCase.requests[before]
        compare(unload.method, "POST")
        compare(unload.url, "http://127.0.0.1:11434/api/chat")
        compare(unload.headers, [["Content-Type", "application/json"]])
        compare(JSON.parse(unload.body), { model: "llama3:latest", messages: [], keep_alive: 0 })
        // Late events of the aborted chat change nothing.
        request.chunk(piece(" again"))
        compare(view.messages.count, 0)
    }

    function test_clearDoesNotUnloadForAStranger() {
        var wrapper = ready()
        var view = wrapper.view
        sendText(view, "Hi").chunk(line({ done: true }))
        var before = testCase.requests.length
        testCase.ownerReply = { ok: true, owner: "other" }
        view.clearConversation(true)
        compare(testCase.requests.length, before)
        compare(view.messages.count, 0)
    }

    // Reopening the popup while the unload check runs must not lose the unload.
    function test_pendingUnloadSurvivesReopen() {
        var wrapper = ready()
        var view = wrapper.view
        sendText(view, "Hi").finish(0, "")
        compare(view.listState, "failed")
        testCase.ownerReply = null
        view.clearConversation(true)
        compare(view.checking, "unload")
        var check = testCase.ownerCommands[testCase.ownerCommands.length - 1]
        var before = testCase.requests.length
        wrapper.shown = false
        wrapper.shown = true
        compare(view.checking, "unload")
        compare(view.unloadNames, ["llama3:latest"])
        compare(testCase.ownerCommands[testCase.ownerCommands.length - 1], check)
        testCase.ownerReply = { ok: true, owner: "system" }
        view.ownerDone(check, { ok: true, owner: "system" })
        compare(testCase.requests.length, before + 2)
        compare(JSON.parse(testCase.requests[before].body), { model: "llama3:latest", messages: [], keep_alive: 0 })
        // The failed list is loaded again after the unload.
        compare(testCase.requests[before + 1].url, "http://127.0.0.1:11434/api/version")
        compare(view.listState, "loading")
    }

    // A send check still running for the old address is never answered.
    function test_addressChangeDuringSendCheckSendsNothing() {
        var wrapper = ready()
        var view = wrapper.view
        input(view).text = "secret"
        testCase.ownerReply = null
        var before = testCase.requests.length
        view.send()
        compare(view.checking, "send")
        var check = testCase.ownerCommands[testCase.ownerCommands.length - 1]
        view.address = "http://127.0.0.1:11435"
        // The new address gets its own check (for the model list).
        var next = testCase.ownerCommands[testCase.ownerCommands.length - 1]
        verify(next !== check)
        verify(/--port-owner 11435$/.test(next), next)
        compare(view.checking, "load")
        view.ownerDone(check, { ok: true, owner: "self" })
        compare(testCase.requests.length, before)
        compare(view.messages.count, 0)
        compare(input(view).text, "secret")
        compare(view.pendingPrompt, "")
        view.ownerDone(next, { ok: true, owner: "self" })
        compare(testCase.requests.length, before + 1)
        compare(testCase.requests[before].method, "GET")
        compare(testCase.requests[before].url, "http://127.0.0.1:11435/api/version")
    }

    function test_disablingClearsWithoutContact() {
        var wrapper = ready()
        var view = wrapper.view
        sendText(view, "Hi").chunk(piece("Hello"))
        var before = testCase.requests.length
        var checks = testCase.ownerCommands.length
        wrapper.siteOn = false
        compare(view.messages.count, 0)
        compare(view.modelList.length, 0)
        compare(view.listState, "idle")
        compare(testCase.requests.length, before)
        compare(testCase.ownerCommands.length, checks)
    }

    function test_conversationSurvivesHiding() {
        var wrapper = ready()
        var view = wrapper.view
        sendText(view, "Hi").chunk(line({ message: { role: "assistant", content: "Yo" }, done: true }))
        wrapper.shown = false
        wrapper.shown = true
        compare(view.messages.count, 2)
        compare(view.messages.get(1).body, "Yo")
    }

    // --- keyboard -----------------------------------------------------------------

    function test_enterSendsShiftEnterAddsLine() {
        var wrapper = ready()
        var view = wrapper.view
        var field = input(view)
        field.forceActiveFocus()
        verify(field.activeFocus)
        keyClick(Qt.Key_A)
        keyClick(Qt.Key_Return, Qt.ShiftModifier)
        keyClick(Qt.Key_B)
        compare(field.text, "a\nb")
        compare(testCase.requests.length, 2)
        keyClick(Qt.Key_Return)
        compare(testCase.requests.length, 3)
        compare(JSON.parse(testCase.requests[2].body).messages[0].content, "a\nb")
        compare(field.text, "")
    }

    function test_escapeStopsWithoutClosing() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(piece("Hel"))
        input(view).forceActiveFocus()
        keyClick(Qt.Key_Escape)
        verify(!view.generating)
        compare(view.messages.get(1).phase, "stopped")
        compare(testCase.escapeAtParent, 0)
        // Idle: Esc passes on (the popup closes as usual).
        keyClick(Qt.Key_Escape)
        compare(testCase.escapeAtParent, 1)
    }

    function test_focusGoesToTheInputWhenShown() {
        var wrapper = make({ shown: false })
        wrapper.forceActiveFocus()
        wrapper.shown = true
        tryVerify(function () { return input(wrapper.view).activeFocus })
    }

    // --- untrusted text is plain text ---------------------------------------------

    function collect(item, out) {
        if (!item || out.indexOf(item) >= 0)
            return
        out.push(item)
        var kids = item.children || []
        for (var index = 0; index < kids.length; index++)
            collect(kids[index], out)
        if (item.contentItem)
            collect(item.contentItem, out)
    }

    // Every text the view sets on a control itself (never server text).
    property var fixedTexts: ["", "Clear this conversation?", "Clear", "Cancel", "Copy reply",
        "Copy code", "Retry", "Reload models", "Send", "Stop", "Back to bottom", "New messages",
        "Message (Enter sends, Shift+Enter adds a line)"]

    function test_everyShownTextIsPlain() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "<b>mine</b>")
        request.chunk(piece("<img src=\"http://127.0.0.1:9/x\"> <b>b</b>\n```html\n<i>code</i>\n```\n![x](http://127.0.0.1:9/y)"))
        request.chunk(line({ done: true }))
        wait(50)
        var items = []
        collect(view, items)
        var formatted = 0
        var marked = 0
        for (var index = 0; index < items.length; index++) {
            var item = items[index]
            if (item.textFormat === undefined || typeof item.text !== "string")
                continue
            formatted += 1
            if (item.text.indexOf("<") >= 0)
                marked += 1
            // Labels inside the controls (buttons, actions, placeholders,
            // the inline message) keep their style's format; they only
            // ever show the view's own fixed texts.
            if (item.textFormat !== Text.PlainText)
                verify(testCase.fixedTexts.indexOf(item.text) >= 0,
                       "not plain text at " + item + ": " + item.text)
        }
        // The user's message, the reply text and the code block.
        verify(marked >= 3, "found " + marked)
        verify(formatted > marked, "found " + formatted)
    }

    // --- hidden direction characters are shown and copied as markers ----------

    TextEdit {
        id: pasteTarget
        visible: false
        textFormat: TextEdit.PlainText
    }

    // The shown item with this objectName (each message has its own).
    function named(view, name) {
        var items = []
        collect(view, items)
        for (var index = 0; index < items.length; index++) {
            if (items[index].objectName === name && items[index].visible)
                return items[index]
        }
        return null
    }

    function pasted() {
        pasteTarget.text = ""
        pasteTarget.paste()
        return pasteTarget.text
    }

    function test_hiddenCharactersAreShownAndCopiedMarked() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "How do I clean?")
        request.chunk(piece("Run:\n```sh\nrm -rf ./build ‮⁦# keep ~⁩\n```\nDone​."))
        request.chunk(line({ done: true }))
        wait(50)
        var items = []
        collect(view, items)
        var shownCode = null
        for (var index = 0; index < items.length; index++) {
            var text = items[index].text
            if (typeof text !== "string")
                continue
            verify(!/[‪-‮⁦-⁩​-‏]/.test(text), "raw hidden character shown: " + text)
            if (text.indexOf("rm -rf") >= 0 && items[index].textFormat !== undefined)
                shownCode = text
        }
        compare(shownCode, "rm -rf ./build ⟦U+202E⟧⟦U+2066⟧# keep ~⟦U+2069⟧")
        var note = named(view, "hiddenCharsNote")
        verify(note !== null && note.visible)
        compare(note.textFormat, Text.PlainText)

        var copyCode = null
        var copyReply = null
        for (index = 0; index < items.length; index++) {
            if (!items[index].visible || !items[index].clicked)
                continue
            if (items[index].text === "Copy code")
                copyCode = items[index]
            if (items[index].text === "Copy reply")
                copyReply = items[index]
        }
        verify(copyCode !== null && copyReply !== null)
        copyCode.clicked()
        compare(pasted(), shownCode)
        copyReply.clicked()
        compare(pasted(), "Run:\n```sh\n" + shownCode + "\n```\nDone⟦U+200B⟧.")
    }

    function test_ordinaryReplyHasNoNote() {
        var wrapper = ready()
        var view = wrapper.view
        var request = sendText(view, "Hi")
        request.chunk(piece("Hello é 日本 שלום"))
        request.chunk(line({ done: true }))
        wait(50)
        var note = named(view, "hiddenCharsNote")
        compare(note, null)
    }

    // --- text size (Ctrl+= / Ctrl+- / Ctrl+0) -------------------------------

    function test_zoomKeysOnlyWhileShown() {
        var wrapper = make({ shown: false })
        var asked = []
        wrapper.view.zoomRequested.connect(function (direction) { asked.push(direction) })
        keyClick(Qt.Key_Equal, Qt.ControlModifier)
        compare(asked, [])
        wrapper.shown = true
        keyClick(Qt.Key_Equal, Qt.ControlModifier)
        keyClick(Qt.Key_Minus, Qt.ControlModifier)
        keyClick(Qt.Key_0, Qt.ControlModifier)
        compare(asked, [1, -1, 0])
    }

    function test_textScaleSizesTranscriptAndInput() {
        var wrapper = ready()
        var view = wrapper.view
        var field = input(view)
        var base = field.font.pointSize > 0 ? field.font.pointSize : field.font.pixelSize
        verify(base > 0)
        view.textScale = 1.5
        var scaled = field.font.pointSize > 0 ? field.font.pointSize : field.font.pixelSize
        fuzzyCompare(scaled, base * 1.5, 1)
        compare(view.bodyFont.family, field.font.family)
        verify((view.codeFont.pointSize > 0 ? view.codeFont.pointSize : view.codeFont.pixelSize) > base)
        view.textScale = 1.0
        compare(field.font.pointSize > 0 ? field.font.pointSize : field.font.pixelSize, base)
    }

    function test_ctrlWheelStepsTextScale() {
        var wrapper = ready()
        var view = wrapper.view
        var asked = []
        view.zoomRequested.connect(function (direction) { asked.push(direction) })
        var transcript = findChild(view, "transcript")
        var field = input(view)
        mouseWheel(transcript, 50, 50, 0, 120, Qt.NoButton, Qt.ControlModifier)
        mouseWheel(transcript, 50, 50, 0, -120, Qt.NoButton, Qt.ControlModifier)
        mouseWheel(field, 10, 10, 0, 120, Qt.NoButton, Qt.ControlModifier)
        compare(asked, [1, -1, 1])
        // Touchpad-sized moves add up to one step.
        mouseWheel(field, 10, 10, 0, 60, Qt.NoButton, Qt.ControlModifier)
        compare(asked.length, 3)
        mouseWheel(field, 10, 10, 0, 60, Qt.NoButton, Qt.ControlModifier)
        compare(asked, [1, -1, 1, 1])
        // A plain wheel scrolls and never zooms.
        mouseWheel(transcript, 50, 50, 0, 120)
        mouseWheel(field, 10, 10, 0, -120)
        compare(asked.length, 4)
    }

    function test_ctrlWheelOnlyWhileShown() {
        var wrapper = make({ shown: false })
        var asked = []
        wrapper.view.zoomRequested.connect(function (direction) { asked.push(direction) })
        mouseWheel(findChild(wrapper.view, "transcript"), 50, 50, 0, 120, Qt.NoButton, Qt.ControlModifier)
        compare(asked, [])
    }

    // --- the transcript follows the reply -----------------------------------

    function atBottom(list) {
        var end = list.originY + list.contentHeight + list.bottomMargin - list.height
        return list.contentY >= end - 2
    }

    function paragraphs(from, count) {
        var text = ""
        for (var index = from; index < from + count; index++)
            text += "Paragraph " + index + " of a reply that streams in.\n\n"
        return text
    }

    function test_transcriptFollowsTheReply() {
        var wrapper = ready()
        var view = wrapper.view
        var list = findChild(view, "transcript")
        var request = sendText(view, "Tell me a long story")
        // Each chunk: wait for its layout (the height grows), then check.
        var grown = 0
        for (var chunk = 0; chunk < 8; chunk++) {
            request.chunk(piece(paragraphs(chunk * 10, 10)))
            tryVerify(function () { return list.contentHeight > grown }, 2000, "chunk " + chunk + " not laid out")
            grown = list.contentHeight
            tryVerify(function () { return atBottom(list) }, 2000, "not at the bottom after chunk " + chunk)
        }
        verify(list.contentHeight > list.height * 2,
               "the transcript must be taller than the view: " + list.contentHeight + " / " + list.height)

        // The user scrolls up: a new chunk doesn't move them.
        mouseWheel(list, 50, 50, 0, 600)
        tryVerify(function () { return !atBottom(list) && !list.moving })
        wait(50)
        var kept = list.contentY
        var height = list.contentHeight
        request.chunk(piece(paragraphs(80, 5)))
        tryVerify(function () { return list.contentHeight > height })
        wait(100)
        fuzzyCompare(list.contentY, kept, 1)
        verify(!view.followTranscript)

        // The user scrolls back to the bottom: it follows again.
        mouseWheel(list, 50, 50, 0, -6000)
        tryVerify(function () { return atBottom(list) && !list.moving })
        tryVerify(function () { return view.followTranscript })
        height = list.contentHeight
        request.chunk(piece(paragraphs(85, 5)))
        tryVerify(function () { return list.contentHeight > height })
        tryVerify(function () { return atBottom(list) }, 2000)
        request.chunk(line({ done: true, done_reason: "stop", message: { role: "assistant", content: "" } }))
        verify(!view.generating)

        // Scrolled up, then a new message: sending always jumps down.
        mouseWheel(list, 50, 50, 0, 600)
        tryVerify(function () { return !atBottom(list) })
        var second = sendText(view, "And then?")
        tryVerify(function () { return atBottom(list) }, 2000)
        height = list.contentHeight
        second.chunk(piece(paragraphs(100, 6)))
        tryVerify(function () { return list.contentHeight > height })
        tryVerify(function () { return atBottom(list) }, 2000)
    }

    function test_backToBottom() {
        var wrapper = ready()
        var view = wrapper.view
        var list = findChild(view, "transcript")
        var button = findChild(view, "backToBottom")
        verify(button !== null)
        var request = sendText(view, "Tell me a long story")
        var grown = 0
        for (var chunk = 0; chunk < 6; chunk++) {
            request.chunk(piece(paragraphs(chunk * 10, 10)))
            tryVerify(function () { return list.contentHeight > grown }, 2000)
            grown = list.contentHeight
        }
        tryVerify(function () { return atBottom(list) }, 2000)
        // Hidden at the bottom.
        verify(!view.showBackToBottom)
        tryVerify(function () { return !button.visible })

        // Shown after scrolling up; the label is fixed text.
        mouseWheel(list, 50, 50, 0, 600)
        tryVerify(function () { return !list.moving && view.showBackToBottom })
        tryVerify(function () { return button.visible && button.opacity === 1 })
        compare(button.text, "New messages")
        compare(button.focusPolicy, Qt.NoFocus)
        // It sits above the message box, never over it.
        var field = input(view)
        var buttonBottom = button.mapToItem(view, 0, button.height).y
        verify(buttonBottom <= field.mapToItem(view, 0, 0).y, buttonBottom + " overlaps the input")

        // Click: at the bottom, following again, hidden; the input keeps the focus.
        field.forceActiveFocus()
        mouseClick(button)
        tryVerify(function () { return atBottom(list) }, 2000)
        verify(view.followTranscript)
        verify(field.activeFocus)
        tryVerify(function () { return !button.visible })
        // And it keeps following the reply.
        request.chunk(piece(paragraphs(60, 6)))
        tryVerify(function () { return list.contentHeight > grown }, 2000)
        tryVerify(function () { return atBottom(list) }, 2000)

        // Done replying: the plain label.
        request.chunk(line({ done: true, done_reason: "stop", message: { role: "assistant", content: "" } }))
        mouseWheel(list, 50, 50, 0, 600)
        tryVerify(function () { return !list.moving && button.visible })
        compare(button.text, "Back to bottom")
    }

    // --- nothing paints outside the view --------------------------------------

    function test_viewAndTranscriptClip() {
        var view = make({ shown: true }).view
        verify(view.clip)
        verify(findChild(view, "transcript").clip)
        verify(findChild(view, "inputScroll").clip)
        verify(findChild(view, "backToBottom").parent.clip)
    }

    function headerIsClean(header) {
        var image = grabImage(header)
        for (var y = 2; y < header.height - 2; y += 4) {
            for (var x = 2; x < header.width - 2; x += 8) {
                if (!Qt.colorEqual(image.pixel(x, y), "#ff00ff"))
                    return "x=" + x + " y=" + y + " is " + image.pixel(x, y)
            }
        }
        return ""
    }

    // Scrolled messages never paint over the tabs above the view.
    function test_scrolledTranscriptStaysBelowTheTabs() {
        var wrapper = ready(undefined, headedComponent)
        var view = wrapper.view
        var list = findChild(view, "transcript")
        var request = sendText(view, "Tell me a long story")
        var grown = 0
        for (var chunk = 0; chunk < 6; chunk++) {
            request.chunk(piece(paragraphs(chunk * 10, 10)))
            tryVerify(function () { return list.contentHeight > grown }, 2000)
            grown = list.contentHeight
        }
        request.chunk(line({ done: true, done_reason: "stop", message: { role: "assistant", content: "" } }))
        verify(view.mapToItem(wrapper, 0, 0).y >= wrapper.header.height)
        // Mid-way: messages above the view's top edge exist and must be clipped.
        list.contentY = list.contentHeight / 2
        wait(100)
        compare(headerIsClean(wrapper.header), "")
        list.contentY = list.originY - list.topMargin
        wait(100)
        compare(headerIsClean(wrapper.header), "")
    }
}
