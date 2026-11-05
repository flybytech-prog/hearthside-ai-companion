.pragma library

// Chat tab websites. Kept here only; the usage catalog (ProviderCatalog.js)
// is unrelated. Hosts match exactly or as a dot-suffix, case-insensitively;
// a user's custom address adds only its exact host.
var sites = [
    {
        id: "claude",
        name: "Claude",
        url: "https://claude.ai/new",
        icon: "provider-claude.svg",
        site_hosts: ["claude.ai", "claude.com", "anthropic.com"],
        auth_hosts: ["accounts.google.com", "appleid.apple.com"]
    },
    {
        id: "chatgpt",
        name: "ChatGPT",
        url: "https://chatgpt.com/",
        icon: "provider-codex.svg",
        site_hosts: ["chatgpt.com", "openai.com"],
        auth_hosts: [
            "accounts.google.com",
            "login.microsoftonline.com",
            "login.live.com",
            "appleid.apple.com"
        ]
    },
    {
        id: "grok",
        name: "Grok",
        url: "https://grok.com/",
        icon: "provider-grok.svg",
        site_hosts: ["grok.com", "x.ai", "x.com"],
        auth_hosts: ["accounts.google.com", "appleid.apple.com"]
    },
    {
        id: "gemini",
        name: "Gemini",
        url: "https://gemini.google.com/app",
        icon: "provider-gemini.svg",
        site_hosts: ["gemini.google.com", "accounts.google.com", "consent.google.com"],
        auth_hosts: ["accounts.google.com"]
    },
    {
        id: "copilot",
        name: "GitHub Copilot",
        // Signed-out visitors to /copilot get a landing page, not the sign-in.
        url: "https://github.com/login?return_to=%2Fcopilot",
        icon: "provider-copilot.svg",
        site_hosts: ["github.com"],
        auth_hosts: ["github.com", "accounts.google.com", "appleid.apple.com"]
    },
    {
        id: "mscopilot",
        name: "Microsoft Copilot",
        url: "https://copilot.microsoft.com/",
        icon: "provider-mscopilot.svg",
        site_hosts: ["copilot.microsoft.com", "microsoft.com", "bing.com"],
        auth_hosts: [
            "login.microsoftonline.com",
            "login.live.com",
            "account.live.com",
            "accounts.google.com",
            "appleid.apple.com"
        ]
    },
    {
        // A chat server on this computer. Plain http is allowed only here and
        // only for the exact loopback origin of its address.
        id: "local",
        name: "Local web UI (Open WebUI)",
        url: "http://localhost:3000/",
        icon: "provider-local.svg",
        site_hosts: ["localhost", "127.0.0.1", "[::1]"],
        auth_hosts: [],
        local: true,
        default_on: false
    }
]

var MAX_CUSTOM_URL_LENGTH = 2048

function siteIds() {
    return sites.map(function (site) { return site.id })
}

function byId(siteId) {
    for (var index = 0; index < sites.length; index++) {
        if (sites[index].id === siteId)
            return sites[index]
    }
    return null
}

// Sites that are on unless the user turns them off.
function defaultSiteIds() {
    return sites.filter(function (site) { return site.default_on !== false })
        .map(function (site) { return site.id })
}

// Sites enabled by the chatSites config JSON, always in catalog order.
// Unreadable config falls back to the default-on sites only.
function enabledSites(json) {
    var wanted = null
    try {
        var parsed = JSON.parse(json || "")
        if (Array.isArray(parsed))
            wanted = parsed
    } catch (error) {
    }
    if (wanted === null)
        wanted = defaultSiteIds()
    return sites.filter(function (site) { return wanted.indexOf(site.id) >= 0 })
}

function initialSite(enabledIds, configuredDefault) {
    var ids = Array.isArray(enabledIds) ? enabledIds : []
    if (ids.indexOf(configuredDefault) >= 0)
        return configuredDefault
    return ids.length > 0 ? ids[0] : ""
}

function normalizeHost(host) {
    if (typeof host !== "string")
        return ""
    var normalized = host.toLowerCase()
    if (normalized.charAt(normalized.length - 1) === ".")
        normalized = normalized.slice(0, -1)
    return normalized
}

function hostMatches(host, list) {
    if (typeof host !== "string" || host === "" || !Array.isArray(list))
        return false
    var normalized = normalizeHost(host)
    for (var index = 0; index < list.length; index++) {
        var entry = String(list[index]).toLowerCase()
        if (entry === "")
            continue
        if (normalized === entry
                || normalized.slice(-(entry.length + 1)) === "." + entry)
            return true
    }
    return false
}

// Exact host equality only; custom addresses never cover subdomains.
function exactHostMatches(host, list) {
    if (typeof host !== "string" || host === "" || !Array.isArray(list))
        return false
    var normalized = normalizeHost(host)
    for (var index = 0; index < list.length; index++) {
        var entry = normalizeHost(String(list[index]))
        if (entry !== "" && normalized === entry)
            return true
    }
    return false
}

// The three spellings of this computer that Local may use over plain http.
function isLoopbackHost(host) {
    var normalized = normalizeHost(host)
    return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "[::1]"
}

// Numeric value of an IPv4 literal in any form the browser accepts
// (127.1, 0x7f000001, 017700000001...), -1 when it can't be one.
function ipv4Value(host) {
    var parts = host.split(".")
    if (parts.length > 4)
        return -1
    var numbers = []
    for (var index = 0; index < parts.length; index++) {
        var part = parts[index]
        var number
        if (/^0x[0-9a-f]*$/.test(part))
            number = part.length > 2 ? parseInt(part.slice(2), 16) : 0
        else if (/^0[0-7]+$/.test(part))
            number = parseInt(part.slice(1), 8)
        else if (/^(0|[1-9][0-9]*)$/.test(part))
            number = parseInt(part, 10)
        else
            return -1
        numbers.push(number)
    }
    var value = 0
    for (var head = 0; head < numbers.length - 1; head++) {
        if (numbers[head] > 255)
            return -1
        value = value * 256 + numbers[head]
    }
    var room = Math.pow(256, 5 - numbers.length)
    var last = numbers[numbers.length - 1]
    if (last >= room)
        return -1
    return value * room + last
}

// Names the usual /etc/hosts gives this computer, beside "localhost".
var LOCAL_NAMES = ["localhost.localdomain", "ip6-localhost", "ip6-loopback"]

// Wider than isLoopbackHost: everything the browser would send to this
// computer. Used only to block, never to allow. Hosts ending in a number
// that isn't a valid IPv4 literal are treated as local (fail closed), and
// so is every name without a dot (the machine's own name, LAN names).
function isLocalAddress(host) {
    var normalized = normalizeHost(host)
    if (normalized === "")
        return false
    if (isLoopbackHost(normalized) || normalized.indexOf(".") < 0
            || LOCAL_NAMES.indexOf(normalized) >= 0
            || normalized.slice(-10) === ".localhost"
            || normalized.slice(-22) === ".localhost.localdomain")
        return true
    var labels = normalized.split(".")
    if (!/^(0x[0-9a-f]*|[0-9]+)$/.test(labels[labels.length - 1]))
        return false
    var value = ipv4Value(normalized)
    return value < 0 || value === 0 || Math.floor(value / 16777216) === 127
}

// Minimal parser: {scheme, host, port} or null when malformed; port is ""
// when absent. Hosts must be plain DNS names, IPv4 or [::1]; user info,
// backslashes and odd characters are treated as hostile.
function parseUrl(value) {
    var text = String(value === undefined || value === null ? "" : value)
    var schemeMatch = /^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/.exec(text)
    if (!schemeMatch)
        return null
    var scheme = schemeMatch[1].toLowerCase()
    var rest = schemeMatch[2]
    if (scheme !== "https" && scheme !== "http")
        return { scheme: scheme, host: "", port: "" }
    if (rest.indexOf("//") !== 0)
        return null
    var authority = rest.slice(2).split(/[\/?#]/)[0]
    if (authority === "" || /[@\\\s%]/.test(authority))
        return null
    var host
    var port
    if (authority.charAt(0) === "[") {
        var bracketMatch = /^(\[::1\])(?::([0-9]{1,5}))?$/.exec(authority)
        if (!bracketMatch)
            return null
        host = bracketMatch[1]
        port = bracketMatch[2]
    } else {
        var hostMatch = /^([A-Za-z0-9.\-]+)(?::([0-9]{1,5}))?$/.exec(authority)
        if (!hostMatch)
            return null
        host = hostMatch[1].toLowerCase()
        port = hostMatch[2]
        if (host.charAt(0) === "." || host.indexOf("..") >= 0)
            return null
    }
    if (port === undefined) {
        port = ""
    } else {
        var number = parseInt(port, 10)
        if (number < 1 || number > 65535)
            return null
        port = String(number)
    }
    return { scheme: scheme, host: host, port: port }
}

function isAboutBlank(value) {
    return String(value === undefined || value === null ? "" : value)
        .toLowerCase() === "about:blank"
}

function isHttpsUrl(value) {
    var parsed = parseUrl(value)
    return parsed !== null && parsed.scheme === "https" && parsed.host !== ""
}

// "host:port" of a parsed http URL, port 80 when absent.
function httpOrigin(parsed) {
    return normalizeHost(parsed.host) + ":" + (parsed.port !== "" ? parsed.port : "80")
}

// {ok, url, error} for a custom address typed by the user. Empty means
// "use the built-in address". The text is checked as given (callers trim).
function validateCustomUrl(siteId, text) {
    var fail = function (code) { return { ok: false, url: "", error: code } }
    var site = byId(siteId)
    if (!site)
        return fail("unknown-site")
    var value = text === undefined || text === null ? "" : String(text)
    if (value === "")
        return { ok: true, url: "", error: "" }
    if (value.length > MAX_CUSTOM_URL_LENGTH)
        return fail("too-long")
    if (/[\s\u0000-\u001f\u007f]/.test(value))
        return fail("whitespace")
    var authorityMatch = /^[A-Za-z][A-Za-z0-9+.\-]*:\/\/([^\/?#]*)/.exec(value)
    if (authorityMatch && authorityMatch[1].indexOf("@") >= 0)
        return fail("userinfo")
    var schemeMatch = /^([A-Za-z][A-Za-z0-9+.\-]*):/.exec(value)
    if (!schemeMatch)
        return fail("malformed")
    var scheme = schemeMatch[1].toLowerCase()
    if (scheme !== "https" && !(scheme === "http" && site.local === true))
        return fail("scheme")
    var parsed = parseUrl(value)
    if (parsed === null || parsed.host === "")
        return fail("malformed")
    if (parsed.scheme === "http" && !isLoopbackHost(parsed.host))
        return fail("http-not-loopback")
    if (site.local !== true && isLocalAddress(parsed.host))
        return fail("loopback-not-allowed")
    return { ok: true, url: value, error: "" }
}

// {url, error} for one settings row: url is what to save for the text the
// user has typed so far. Valid text (trimmed) or empty is saved as is;
// invalid text saves baseline, the value saved when the page opened, so a
// half-typed secret such as "https://admin:1234" never outlives the "@".
function customUrlToPersist(siteId, text, baseline) {
    var value = text === undefined || text === null ? "" : String(text).trim()
    var checked = validateCustomUrl(siteId, value)
    if (checked.ok)
        return { url: checked.url, error: "" }
    var fallback = validateCustomUrl(siteId, baseline)
    return { url: fallback.ok ? fallback.url : "", error: checked.error }
}

// Only known ids with a valid non-empty address, in catalog order.
function filterCustomUrls(map) {
    var result = {}
    if (map === null || typeof map !== "object" || Array.isArray(map))
        return result
    for (var index = 0; index < sites.length; index++) {
        var id = sites[index].id
        if (!Object.prototype.hasOwnProperty.call(map, id) || typeof map[id] !== "string")
            continue
        var checked = validateCustomUrl(id, map[id])
        if (checked.ok && checked.url !== "")
            result[id] = checked.url
    }
    return result
}

// The chatCustomUrls config JSON as {siteId: url}; anything odd → {}.
function parseCustomUrls(json) {
    var parsed = null
    try {
        parsed = JSON.parse(typeof json === "string" ? json : "")
    } catch (error) {
    }
    return filterCustomUrls(parsed)
}

function serializeCustomUrls(map) {
    return JSON.stringify(filterCustomUrls(map))
}

// The site with the user's custom address applied, or null when unknown.
// The address is re-validated on every call; invalid falls back to built-in.
function effectiveSite(siteId, customUrls) {
    var site = byId(siteId)
    if (!site)
        return null
    var custom = ""
    if (customUrls !== null && typeof customUrls === "object" && !Array.isArray(customUrls)
            && Object.prototype.hasOwnProperty.call(customUrls, site.id)
            && typeof customUrls[site.id] === "string") {
        var checked = validateCustomUrl(site.id, customUrls[site.id])
        if (checked.ok)
            custom = checked.url
    }
    var url = custom !== "" ? custom : site.url
    var parsed = parseUrl(url)
    return {
        id: site.id,
        name: site.name,
        url: url,
        icon: site.icon,
        site_hosts: site.site_hosts.slice(),
        auth_hosts: site.auth_hosts.slice(),
        exact_hosts: custom !== "" ? [normalizeHost(parsed.host)] : [],
        local: site.local === true,
        default_on: site.default_on !== false,
        http_origin: site.local === true && parsed.scheme === "http" ? httpOrigin(parsed) : ""
    }
}

function homeUrl(siteId, customUrls) {
    var site = effectiveSite(siteId, customUrls)
    return site ? site.url : ""
}

function knownHost(site, host) {
    return hostMatches(host, site.site_hosts) || hostMatches(host, site.auth_hosts)
        || exactHostMatches(host, site.exact_hosts)
}

// Local http is allowed only for the exact loopback origin of its address.
function httpAllowed(site, parsed) {
    return site.local === true && typeof site.http_origin === "string"
        && site.http_origin !== "" && isLoopbackHost(parsed.host)
        && httpOrigin(parsed) === site.http_origin
}

// Whether url is a page of site that may be handed to the browser.
function isPageUrl(site, url) {
    if (!site)
        return false
    var parsed = parseUrl(url)
    if (parsed === null || parsed.host === "")
        return false
    if (parsed.scheme === "https")
        return site.local === true || !isLocalAddress(parsed.host)
    if (parsed.scheme === "http")
        return httpAllowed(site, parsed)
    return false
}

// "allow" | "external" | "block" for a WebEngine navigation request.
// request.customUrls is optional; without it the built-in addresses apply.
function classifyNavigation(request) {
    var info = request || {}
    // Only an explicit subframe gets the looser rules; missing info is
    // treated as the main frame.
    if (info.isMainFrame === false)
        return classifySubframe(info)
    var site = effectiveSite(info.siteId, info.customUrls)
    if (!site)
        return "block"
    if (isAboutBlank(info.url))
        return "allow"
    var parsed = parseUrl(info.url)
    if (parsed === null)
        return "block"
    if (parsed.host !== "" && !site.local && isLocalAddress(parsed.host))
        return "block"
    if (parsed.scheme === "https") {
        if (info.linkClicked && !knownHost(site, parsed.host))
            return "external"
        return "allow"
    }
    if (parsed.scheme === "http")
        return httpAllowed(site, parsed) ? "allow" : "block"
    return "block"
}

// --- Local web UI owner check -------------------------------------------------

// The port whose owner the helper must vouch for (self or system) before
// the main frame of a Local page goes to url: any address on this computer,
// default port by scheme. 0 when no check applies (other sites, other hosts,
// about:blank, unreadable addresses; those are blocked by classifyNavigation).
function localOwnerPort(request) {
    var info = request || {}
    var site = effectiveSite(info.siteId, info.customUrls)
    if (!site || site.local !== true)
        return 0
    var parsed = parseUrl(info.url)
    if (parsed === null || parsed.host === ""
            || (parsed.scheme !== "http" && parsed.scheme !== "https")
            || !isLocalAddress(parsed.host))
        return 0
    if (parsed.port !== "")
        return parseInt(parsed.port, 10)
    return parsed.scheme === "https" ? 443 : 80
}

// "skip" | "go" | "check" for a navigation request: "check" means reject it
// and ask the helper first. request.pass is the address a good check was
// just made for; it is used up by this navigation whatever the result.
// Subframes are not gated.
function localOwnerGate(request) {
    var info = request || {}
    if (info.isMainFrame === false || localOwnerPort(info) === 0)
        return "skip"
    var url = info.url === undefined || info.url === null ? "" : String(info.url)
    return typeof info.pass === "string" && info.pass !== "" && info.pass === url ? "go" : "check"
}

// --- Off-site notice ----------------------------------------------------------

var MAX_HOST_DISPLAY = 64

function punycodeDigit(digit) {
    return String.fromCharCode(digit < 26 ? 97 + digit : 22 + digit)
}

function punycodeAdapt(delta, points, first) {
    delta = first ? Math.floor(delta / 700) : Math.floor(delta / 2)
    delta += Math.floor(delta / points)
    var k = 0
    while (delta > 455) {
        delta = Math.floor(delta / 35)
        k += 36
    }
    return k + Math.floor(36 * delta / (delta + 38))
}

// RFC 3492 encoding of one label's code points (without "xn--"); "" on overflow.
function punycodeEncode(codePoints) {
    var output = []
    for (var index = 0; index < codePoints.length; index++) {
        if (codePoints[index] < 128)
            output.push(String.fromCharCode(codePoints[index]))
    }
    var basic = output.length
    var handled = basic
    if (basic > 0)
        output.push("-")
    var n = 128
    var delta = 0
    var bias = 72
    while (handled < codePoints.length) {
        var next = 0x10ffff + 1
        for (index = 0; index < codePoints.length; index++) {
            if (codePoints[index] >= n && codePoints[index] < next)
                next = codePoints[index]
        }
        delta += (next - n) * (handled + 1)
        if (delta > 0x7fffffff)
            return ""
        n = next
        for (index = 0; index < codePoints.length; index++) {
            var point = codePoints[index]
            if (point < n)
                delta++
            if (point !== n)
                continue
            var q = delta
            for (var k = 36; ; k += 36) {
                var t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                if (q < t)
                    break
                output.push(punycodeDigit(t + (q - t) % (36 - t)))
                q = Math.floor((q - t) / (36 - t))
            }
            output.push(punycodeDigit(q))
            bias = punycodeAdapt(delta, handled + 1, handled === basic)
            delta = 0
            handled++
        }
        delta++
        n++
    }
    return output.join("")
}

function codePointsOf(text) {
    var points = []
    for (var index = 0; index < text.length; index++) {
        var code = text.charCodeAt(index)
        if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
            var low = text.charCodeAt(index + 1)
            if (low >= 0xdc00 && low <= 0xdfff) {
                points.push((code - 0xd800) * 0x400 + (low - 0xdc00) + 0x10000)
                index++
                continue
            }
        }
        points.push(code)
    }
    return points
}

// The host of an http(s) address as plain ASCII: lower case, without user
// info, port or final dot; international labels as their "xn--" form, so
// look-alike letters can't pass for the real name. "" when there is no
// readable host.
function displayHost(url) {
    var text = String(url === undefined || url === null ? "" : url)
    var match = /^https?:\/\/([^\/?#]*)/i.exec(text)
    if (!match)
        return ""
    var authority = match[1]
    // Browsers read "\" as "/", so "evil.example\@good.example" is on
    // evil.example: unreadable rather than guessed.
    if (authority.indexOf("\\") >= 0)
        return ""
    authority = authority.slice(authority.lastIndexOf("@") + 1)
    var host
    if (authority.charAt(0) === "[") {
        var end = authority.indexOf("]")
        host = end > 0 ? authority.slice(0, end + 1).toLowerCase() : ""
        return /^\[[0-9a-f:.]+\]$/.test(host) ? host : ""
    }
    host = authority.replace(/:[0-9]*$/, "").toLowerCase()
    if (host.charAt(host.length - 1) === ".")
        host = host.slice(0, -1)
    if (host === "" || /[\u0000- %\\]/.test(host))
        return ""
    var labels = host.split(/[.。．｡]/)
    for (var index = 0; index < labels.length; index++) {
        var label = labels[index]
        if (/^[\u0000-\u007f]*$/.test(label))
            continue
        var encoded = punycodeEncode(codePointsOf(label))
        if (encoded === "")
            return ""
        labels[index] = "xn--" + encoded
    }
    host = labels.join(".")
    return /^[a-z0-9_\-]+(?:\.[a-z0-9_\-]+)*$/.test(host) ? host : ""
}

// Long hosts keep their end, where the real domain is.
function shortHost(host) {
    var text = String(host || "")
    return text.length > MAX_HOST_DISPLAY ? "…" + text.slice(-(MAX_HOST_DISPLAY - 1)) : text
}

// {off, host} for the page shown in a site's main frame: off when it is an
// http(s) page on a host outside the site's own, sign-in and custom hosts.
// host is shortHost(displayHost(url)), "" when unreadable (still off).
function offSiteHost(request) {
    var info = request || {}
    var site = effectiveSite(info.siteId, info.customUrls)
    var url = info.url === undefined || info.url === null ? "" : String(info.url)
    if (!site || !/^https?:/i.test(url))
        return { off: false, host: "" }
    var host = displayHost(url)
    if (host !== "" && knownHost(site, host))
        return { off: false, host: "" }
    return { off: true, host: shortHost(host) }
}

// {kind, host} naming a sign-in window: "page" with the host of its own
// http(s) address; while it has none (about:blank, empty, a page it was
// written into) "opener" with the host of request.openerUrl, the page that
// opened it; "unknown" when neither is readable. Hosts as in offSiteHost.
function overlayHost(request) {
    var info = request || {}
    var own = displayHost(info.url)
    if (own !== "")
        return { kind: "page", host: shortHost(own) }
    var opener = displayHost(info.openerUrl)
    if (opener !== "")
        return { kind: "opener", host: shortHost(opener) }
    return { kind: "unknown", host: "" }
}

// "allow" | "block" for an embedded frame. Frames may load https from any
// host and about:, blob:, data: or srcdoc content, but never this computer
// unless the site is Local, and Local frames get plain http only for the
// exact origin of its address. Unreadable http(s) addresses are blocked.
function classifySubframe(info) {
    var url = info.url === undefined || info.url === null ? "" : String(info.url)
    var parsed = parseUrl(url)
    if (parsed === null)
        return /^https?:/i.test(url) ? "block" : "allow"
    if (parsed.scheme !== "http" && parsed.scheme !== "https")
        return "allow"
    var site = effectiveSite(info.siteId, info.customUrls)
    if (site === null || site.local !== true)
        return isLocalAddress(parsed.host) ? "block" : "allow"
    if (parsed.scheme === "http")
        return httpAllowed(site, parsed) ? "allow" : "block"
    return "allow"
}

// "overlay" | "external" | "block" for a new-window request. Plain http is
// always blocked here, even for Local. A sign-in window ("overlay") opens
// only for a click (request.userInitiated === true); a script-opened one is
// blocked.
function classifyNewWindow(request) {
    var info = request || {}
    var site = effectiveSite(info.siteId, info.customUrls)
    if (!site)
        return "block"
    var url = info.url === undefined || info.url === null ? "" : String(info.url)
    var parsed = parseUrl(url)
    if (parsed !== null && parsed.host !== "" && !site.local && isLocalAddress(parsed.host))
        return "block"
    var https = isHttpsUrl(url)
    var clicked = info.userInitiated === true
    if (info.isDialog && (https || url === "" || isAboutBlank(url)))
        return clicked ? "overlay" : "block"
    if (!https)
        return "block"
    if (hostMatches(parsed.host, site.auth_hosts))
        return clicked ? "overlay" : "block"
    return "external"
}

// Drops only the QtWebEngine/x.y.z product token; Chrome/platform stay intact.
function userAgent(defaultUa) {
    if (typeof defaultUa !== "string")
        return ""
    return defaultUa.replace(/\s*QtWebEngine\/\S+/g, "")
}

// Google's sign-in refuses embedded Chromium ("This browser or app may not be
// secure") but accepts a desktop Firefox, as qutebrowser found. Used only on
// that one page; everywhere else the real engine is announced.
var GOOGLE_SIGNIN_HOST = "accounts.google.com"
var GOOGLE_SIGNIN_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

// https on exactly accounts.google.com (default port); no subdomains, look-
// alike suffixes, user info or other schemes.
function isGoogleSignInHost(url) {
    var parsed = parseUrl(url)
    return parsed !== null && parsed.scheme === "https"
        && parsed.host === GOOGLE_SIGNIN_HOST
        && (parsed.port === "" || parsed.port === "443")
}

// The user agent for a profile whose pages are at url (one address or a
// list): Firefox while any of them is Google's sign-in, otherwise
// userAgent(defaultUa).
function userAgentFor(url, defaultUa) {
    var urls = Array.isArray(url) ? url : [url]
    for (var index = 0; index < urls.length; index++) {
        if (isGoogleSignInHost(urls[index]))
            return GOOGLE_SIGNIN_UA
    }
    return userAgent(defaultUa)
}

// Preferred popup size in pixels for the given tab ("chat", "split" for the
// web split view, else usage), times scale (Settings → General → Size;
// anything odd is 1), clamped to the screen. Split is wide enough for two
// chat sites side by side.
function popupSize(tab, gu, availW, availH, scale) {
    var unit = Number(gu) > 0 ? Number(gu) : 18
    var factor = Number(scale) > 0 && isFinite(Number(scale)) ? Number(scale) : 1
    var minWidth = unit * 18
    var minHeight = unit * 15
    var chat = tab === "chat" || tab === "split"
    var width = Math.round(unit * (tab === "split" ? 52 : chat ? 34 : 23) * factor)
    var height = Math.round(unit * (chat ? 40 : 28) * factor)
    if (Number(availW) > 0)
        width = Math.min(width, Number(availW) - unit * 2)
    if (Number(availH) > 0)
        height = Math.min(height, Number(availH) - unit * 4)
    return { width: Math.max(minWidth, width), height: Math.max(minHeight, height) }
}

// The panel popup's width around split view (FullRepresentation resizes the
// window itself, since Plasma keeps the size it last closed at). In:
// show: split view is shown now; popupWidth, padding: the window's width and
// what it adds around the popup's content; splitWidth, normalWidth:
// popupSize() widths for "split" and for the tab shown without split;
// before: the width to go back to (0: none); repair: the first open of the
// session, when a width saved before narrowing (Plasma restart) is put back;
// maxPadding (optional): the largest padding that can be real.
// Returns {width: the new window width (0: leave it), before}; with
// maxPadding, a widening or repair that would use a padding outside
// 0..maxPadding (the window not laid out yet) returns {width: 0, before,
// wait: true} instead: try again later.
function splitWidthStep(input) {
    var step = input || {}
    var pixels = function (value) {
        var number = Number(value)
        return isFinite(number) && number > 0 ? Math.round(number) : 0
    }
    var popupWidth = pixels(step.popupWidth)
    var padding = pixels(step.padding)
    var before = pixels(step.before)
    var limit = pixels(step.maxPadding)
    var measured = Number(step.padding)
    if (limit > 0 && (step.show === true || step.repair === true)
            && !(isFinite(measured) && measured >= 0 && measured <= limit))
        return { width: 0, before: before, wait: true }
    var split = pixels(step.splitWidth) > 0 ? pixels(step.splitWidth) + padding : 0
    var normal = pixels(step.normalWidth) > 0 ? pixels(step.normalWidth) + padding : 0
    if (step.show === true) {
        // Already wide enough: keep the width to go back to.
        if (split > 0 && popupWidth < split)
            return { width: split, before: before > 0 ? before : popupWidth }
        return { width: 0, before: before }
    }
    if (before > 0)
        return { width: before, before: 0 }
    if (step.repair === true && split > 0 && normal > 0 && normal !== popupWidth
            && Math.abs(popupWidth - split) <= 1)
        return { width: normal, before: 0 }
    return { width: 0, before: 0 }
}
