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
        name: "Local (Ollama / Open WebUI)",
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

// Wider than isLoopbackHost: everything the browser would send to this
// computer. Used only to block, never to allow. Hosts ending in a number
// that isn't a valid IPv4 literal are treated as local (fail closed).
function isLocalAddress(host) {
    var normalized = normalizeHost(host)
    if (normalized === "")
        return false
    if (isLoopbackHost(normalized) || normalized.slice(-10) === ".localhost")
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
// always blocked here, even for Local.
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
    if (info.isDialog && (https || url === "" || isAboutBlank(url)))
        return "overlay"
    if (!https)
        return "block"
    if (hostMatches(parsed.host, site.auth_hosts))
        return "overlay"
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

// Preferred popup size in pixels for the given tab.
function popupSize(tab, gu, availW, availH) {
    var unit = Number(gu) > 0 ? Number(gu) : 18
    var minWidth = unit * 18
    var minHeight = unit * 15
    if (tab !== "chat")
        return { width: unit * 23, height: unit * 28 }
    var width = unit * 34
    var height = unit * 40
    if (Number(availW) > 0)
        width = Math.min(width, Number(availW) - unit * 2)
    if (Number(availH) > 0)
        height = Math.min(height, Number(availH) - unit * 4)
    return { width: Math.max(minWidth, width), height: Math.max(minHeight, height) }
}
