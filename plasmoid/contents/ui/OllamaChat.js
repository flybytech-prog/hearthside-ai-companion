.pragma library

// Built-in Ollama chat. Pure helpers only: OllamaChatView.qml does the
// requests and keeps the conversation in memory. Everything that comes back
// from the server (or the port-owner helper) is untrusted and is reduced here
// to checked values; anything odd fails safe.

var ENTRY = Object.freeze({
    id: "ollama",
    name: "Ollama",
    icon: "provider-local.svg",
    native: true,
    default_on: false
})

var DEFAULT_ADDRESS = "http://127.0.0.1:11434"
var MAX_ADDRESS_LENGTH = 64
var MAX_PROMPT_CHARS = 32000
var MAX_REPLY_CHARS = 200000
var MAX_MODELS = 200
var MAX_SERVER_ERROR_CHARS = 300
var MAX_INT = 2147483648

var LOOPBACK_HOSTS = ["127.0.0.1", "localhost", "[::1]"]
var ENDPOINTS = { version: "/api/version", tags: "/api/tags", chat: "/api/chat" }
var ROLES = ["user", "assistant"]
var OWNERS = ["none", "self", "system", "other"]
var OWNER_ERRORS = ["unreadable"]

// --- Chat site list ---------------------------------------------------------

// Whether the chatSites config JSON turns Ollama on; unreadable → false.
function isEnabled(chatSitesJson) {
    try {
        var parsed = JSON.parse(typeof chatSitesJson === "string" ? chatSitesJson : "")
        return Array.isArray(parsed) && parsed.indexOf(ENTRY.id) >= 0
    } catch (error) {
        return false
    }
}

// The Chat dropdown: web sites first, then Ollama when it is on.
function menuEntries(webSites, chatSitesJson) {
    var sites = Array.isArray(webSites) ? webSites : []
    return sites.concat(isEnabled(chatSitesJson) ? [ENTRY] : [])
}

function allSiteIds(webIds) {
    var ids = Array.isArray(webIds) ? webIds : []
    return ids.filter(function (id) { return id !== ENTRY.id }).concat([ENTRY.id])
}

// --- Address ----------------------------------------------------------------

// {ok, address, error} for the address typed in settings. Only
// http://<127.0.0.1|localhost|[::1]>:<port> with an optional trailing "/" is
// accepted, normalized to "http://host:port". Empty means the default.
function validateAddress(text) {
    var fail = function (code) { return { ok: false, address: "", error: code } }
    var value = text === undefined || text === null ? "" : String(text)
    if (value === "")
        return { ok: true, address: DEFAULT_ADDRESS, error: "" }
    if (value.length > MAX_ADDRESS_LENGTH)
        return fail("too-long")
    if (/[\s\u0000-\u001f\u007f]/.test(value))
        return fail("whitespace")
    var authorityMatch = /^[A-Za-z][A-Za-z0-9+.\-]*:\/\/([^\/?#]*)/.exec(value)
    if (authorityMatch && authorityMatch[1].indexOf("@") >= 0)
        return fail("userinfo")
    var schemeMatch = /^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/.exec(value)
    if (!schemeMatch)
        return fail("malformed")
    if (schemeMatch[1].toLowerCase() !== "http")
        return fail("scheme")
    var rest = schemeMatch[2]
    if (rest.indexOf("//") !== 0)
        return fail("malformed")
    rest = rest.slice(2)
    var authority = rest.split(/[\/?#]/)[0]
    var tail = rest.slice(authority.length)
    var host
    var port
    if (authority.charAt(0) === "[") {
        var bracketMatch = /^(\[[^\]]*\])(?::(.*))?$/.exec(authority)
        if (!bracketMatch)
            return fail("malformed")
        host = bracketMatch[1].toLowerCase()
        port = bracketMatch[2]
    } else {
        var hostMatch = /^([^:]*)(?::(.*))?$/.exec(authority)
        host = hostMatch[1].toLowerCase()
        port = hostMatch[2]
    }
    if (host === "")
        return fail("malformed")
    // Exact names only: no other 127/8 address, 0.0.0.0, numeric forms,
    // *.localhost or DNS names that happen to resolve to loopback.
    if (LOOPBACK_HOSTS.indexOf(host) < 0)
        return fail("not-loopback")
    if (port === undefined || port === "")
        return fail("port-missing")
    if (!/^[0-9]+$/.test(port))
        return fail("malformed")
    var number = port.length > 5 ? 0 : parseInt(port, 10)
    if (number < 1 || number > 65535)
        return fail("port-range")
    if (tail !== "" && tail !== "/")
        return fail("path")
    return { ok: true, address: "http://" + host + ":" + number, error: "" }
}

// {address, error} for the settings field: valid text (trimmed) is saved
// normalized; invalid text saves baseline, the value saved when the page
// opened, so a half-typed address never outlives a typo.
function addressToPersist(text, baseline) {
    var value = text === undefined || text === null ? "" : String(text).trim()
    var checked = validateAddress(value)
    if (checked.ok)
        return { address: checked.address, error: "" }
    var fallback = validateAddress(baseline)
    return { address: fallback.ok ? fallback.address : DEFAULT_ADDRESS, error: checked.error }
}

function effectiveAddress(configValue) {
    if (typeof configValue !== "string")
        return DEFAULT_ADDRESS
    var checked = validateAddress(configValue)
    return checked.ok ? checked.address : DEFAULT_ADDRESS
}

// The normalized address, or "" when empty or invalid.
function checkedAddress(address) {
    if (typeof address !== "string" || address === "")
        return ""
    var checked = validateAddress(address)
    return checked.ok ? checked.address : ""
}

// Port number of a valid address, else 0.
function portOf(address) {
    var normalized = checkedAddress(address)
    if (normalized === "")
        return 0
    return parseInt(normalized.slice(normalized.lastIndexOf(":") + 1), 10)
}

function endpoint(address, name) {
    var normalized = checkedAddress(address)
    if (normalized === "" || typeof name !== "string"
            || !Object.prototype.hasOwnProperty.call(ENDPOINTS, name))
        return ""
    return normalized + ENDPOINTS[name]
}

// --- Requests ---------------------------------------------------------------

function isModelName(name) {
    return typeof name === "string" && /^[A-Za-z0-9._:\/+-]{1,200}$/.test(name)
}

// The POST /api/chat body, or "" when anything is off. Only role and content
// are sent; user turns are capped at MAX_PROMPT_CHARS, replies at
// MAX_REPLY_CHARS.
function chatRequestBody(model, messages) {
    if (!isModelName(model) || !Array.isArray(messages) || messages.length === 0)
        return ""
    var clean = []
    for (var index = 0; index < messages.length; index++) {
        var message = messages[index]
        if (!message || typeof message !== "object" || ROLES.indexOf(message.role) < 0
                || typeof message.content !== "string")
            return ""
        var limit = message.role === "user" ? MAX_PROMPT_CHARS : MAX_REPLY_CHARS
        if (message.content.length > limit)
            return ""
        clean.push({ role: message.role, content: message.content })
    }
    return JSON.stringify({ model: model, messages: clean, stream: true })
}

// Asks Ollama to unload the model (and drop its cache). Carries no prompt.
function unloadRequestBody(model) {
    if (!isModelName(model))
        return ""
    return JSON.stringify({ model: model, messages: [], keep_alive: 0 })
}

// --- Responses --------------------------------------------------------------

function parseObject(text) {
    try {
        var value = JSON.parse(typeof text === "string" ? text : "")
        return value && typeof value === "object" && !Array.isArray(value) ? value : null
    } catch (error) {
        return null
    }
}

// A short display word from the server ("8.0B", "llama"), else "".
function safeWord(value) {
    return typeof value === "string" && /^[A-Za-z0-9._ +-]{1,40}$/.test(value) ? value : ""
}

// GET /api/version: proves something Ollama-shaped is answering.
function parseVersion(status, text) {
    var reply = status === 200 ? parseObject(text) : null
    if (reply === null || typeof reply.version !== "string" || reply.version.length > 32
            || !/^[0-9]+\.[0-9]+[0-9A-Za-z.+-]*$/.test(reply.version))
        return { ok: false, error: "not-ollama" }
    return { ok: true, version: reply.version }
}

function isRemoteName(name) {
    var lower = name.toLowerCase()
    return /[:-]cloud$/.test(lower)
}

function hasField(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key)
        && object[key] !== null && object[key] !== undefined
}

// GET /api/tags → installed local chat models in server order. Cloud models
// (they forward prompts to ollama.com) are dropped and counted; models
// without "completion" (embeddings) and bad names are dropped silently.
function parseTags(status, text) {
    if (status !== 200)
        return { ok: false, models: [], hiddenRemote: 0, error: classifyFailure(status) }
    var reply = parseObject(text)
    if (reply === null || !Array.isArray(reply.models))
        return { ok: false, models: [], hiddenRemote: 0, error: "bad-tags" }
    var models = []
    var seen = []
    var hidden = 0
    for (var index = 0; index < reply.models.length && models.length < MAX_MODELS; index++) {
        var entry = reply.models[index]
        if (!entry || typeof entry !== "object" || Array.isArray(entry) || !isModelName(entry.name))
            continue
        if (hasField(entry, "remote_host") || hasField(entry, "remote_model")
                || isRemoteName(entry.name)) {
            hidden++
            continue
        }
        if (hasField(entry, "capabilities")
                && (!Array.isArray(entry.capabilities)
                    || entry.capabilities.indexOf("completion") < 0))
            continue
        if (seen.indexOf(entry.name) >= 0)
            continue
        seen.push(entry.name)
        var details = entry.details && typeof entry.details === "object" ? entry.details : {}
        models.push({
            name: entry.name,
            parameterSize: safeWord(details.parameter_size),
            family: safeWord(details.family)
        })
    }
    return { ok: true, models: models, hiddenRemote: hidden, error: "" }
}

// The previous choice while it is still listed, else the first model.
function pickModel(models, current) {
    var list = Array.isArray(models) ? models : []
    var first = ""
    for (var index = 0; index < list.length; index++) {
        var name = list[index] && list[index].name
        if (!isModelName(name))
            continue
        if (name === current)
            return name
        if (first === "")
            first = name
    }
    return first
}

// --- Streaming reply --------------------------------------------------------

function newStream() {
    return { offset: 0, content: "", thinking: false, done: false, doneReason: "",
             error: "", errorText: "" }
}

function copyStream(state) {
    var value = state && typeof state === "object" ? state : newStream()
    return {
        offset: typeof value.offset === "number" && value.offset >= 0 ? value.offset : 0,
        content: typeof value.content === "string" ? value.content : "",
        thinking: value.thinking === true,
        done: value.done === true,
        doneReason: typeof value.doneReason === "string" ? value.doneReason : "",
        error: typeof value.error === "string" ? value.error : "",
        errorText: typeof value.errorText === "string" ? value.errorText : ""
    }
}

// One NDJSON line into state (mutated). Returns false to stop reading.
function feedLine(state, line) {
    var trimmed = line.trim()
    if (trimmed === "")
        return true
    var chunk = parseObject(trimmed)
    if (chunk === null) {
        state.error = "bad-stream"
        return false
    }
    if (hasField(chunk, "error")) {
        state.error = "server"
        state.errorText = serverErrorText(chunk.error)
        return false
    }
    var message = chunk.message
    if (message && typeof message === "object") {
        if (typeof message.content === "string")
            state.content += message.content
        // Thinking text is never kept; only the fact that it arrives.
        if (typeof message.thinking === "string" && message.thinking !== "")
            state.thinking = true
    }
    if (state.content.length > MAX_REPLY_CHARS) {
        state.content = state.content.slice(0, MAX_REPLY_CHARS)
        state.error = "too-long"
        return false
    }
    if (chunk.done === true) {
        state.done = true
        state.doneReason = typeof chunk.done_reason === "string"
            && /^[a-z_]{1,20}$/.test(chunk.done_reason) ? chunk.done_reason : ""
        return false
    }
    return true
}

// The state after reading responseText (the whole body so far). Only
// complete "\n"-terminated lines from offset are read, plus the last line
// when final. Text before offset ends in a complete line, so later
// re-decoding of the body doesn't move it. After done or an error nothing
// more is read.
function feedStream(state, responseText, final) {
    var next = copyStream(state)
    if (next.done || next.error !== "")
        return next
    var text = typeof responseText === "string" ? responseText : ""
    if (text.length < next.offset)
        return next
    while (true) {
        var end = text.indexOf("\n", next.offset)
        var line
        if (end >= 0) {
            line = text.slice(next.offset, end)
            next.offset = end + 1
        } else if (final === true && next.offset < text.length) {
            line = text.slice(next.offset)
            next.offset = text.length
        } else {
            break
        }
        if (!feedLine(next, line))
            break
    }
    return next
}

function classifyFailure(status) {
    if (status === 0)
        return "not-running"
    if (status === 403)
        return "forbidden"
    if (status === 404)
        return "model-missing"
    if (typeof status === "number" && status >= 500)
        return "server-error"
    return "unexpected"
}

// A server error message made safe for a PlainText label.
function serverErrorText(raw) {
    if (typeof raw !== "string")
        return ""
    return raw.replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, " ")
        .replace(/[<>&]/g, "")
        .replace(/ {2,}/g, " ")
        .trim()
        .slice(0, MAX_SERVER_ERROR_CHARS)
        .trim()
}

// --- Reply layout -----------------------------------------------------------

// [{kind: "text"|"code", text, lang}] split on ``` fence lines. A fence that
// isn't closed yet (still streaming) is code to the end. Whitespace-only text
// between blocks is dropped.
function segments(text) {
    if (typeof text !== "string" || text === "")
        return []
    var result = []
    var lines = text.split("\n")
    var buffer = []
    var inCode = false
    var lang = ""
    var flush = function (kind) {
        var joined = buffer.join("\n")
        if (kind === "code" || joined.trim() !== "")
            result.push({ kind: kind, text: joined, lang: kind === "code" ? lang : "" })
        buffer = []
    }
    for (var index = 0; index < lines.length; index++) {
        var line = lines[index]
        var bare = line.replace(/\r$/, "")
        var fence = /^\s*```+(.*)$/.exec(bare)
        if (!inCode && fence) {
            flush("text")
            var word = fence[1].trim()
            lang = /^[A-Za-z0-9+#.-]{0,20}$/.test(word) ? word : ""
            inCode = true
        } else if (inCode && /^\s*```+\s*$/.test(bare)) {
            flush("code")
            inCode = false
            lang = ""
        } else {
            buffer.push(line)
        }
    }
    flush(inCode ? "code" : "text")
    return result
}

// --- Port owner check -------------------------------------------------------

// A plain integer 0..2**31, else -1 (same rule as ChatStorage.validInt).
function validInt(value) {
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_INT)
        return -1
    return value
}

// The helper command that reports who listens on port. The env words only
// make the DataSource source name unique (same shape as
// ChatStorage.helperPrefix); the helper ignores them. Invalid → "".
function ownerCommand(port, run, applet) {
    if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535
            || validInt(run) < 0 || validInt(applet) < 0)
        return ""
    return "env HEARTHSIDE_RUN=" + run + " HEARTHSIDE_APPLET=" + applet
        + " python3 -m hearthside --port-owner " + port
}

function parseOwnerReply(exitCode, stdout) {
    var bad = { ok: false, error: "bad-reply" }
    if (exitCode !== 0 || typeof stdout !== "string" || stdout.length > 200)
        return bad
    var reply = parseObject(stdout)
    if (reply === null)
        return bad
    if (reply.ok === true && OWNERS.indexOf(reply.owner) >= 0)
        return { ok: true, owner: reply.owner }
    if (reply.ok === false && OWNER_ERRORS.indexOf(reply.error) >= 0)
        return { ok: false, error: reply.error }
    return bad
}

// Whether prompts may go to the program that owns the port.
function trusted(owner) {
    return owner === "self" || owner === "system"
}
