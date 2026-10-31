.pragma library

// Chat tab websites. Kept here only; the usage catalog (ProviderCatalog.js)
// is unrelated. Hosts match exactly or as a dot-suffix, case-insensitively.
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
        url: "https://github.com/copilot",
        icon: "provider-copilot.svg",
        site_hosts: ["github.com"],
        auth_hosts: ["github.com"]
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
    }
]

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

// Sites enabled by the chatSites config JSON, always in catalog order.
function enabledSites(json) {
    var wanted = null
    try {
        var parsed = JSON.parse(json || "")
        if (Array.isArray(parsed))
            wanted = parsed
    } catch (error) {
    }
    if (wanted === null)
        return sites.slice()
    return sites.filter(function (site) { return wanted.indexOf(site.id) >= 0 })
}

function initialSite(enabledIds, configuredDefault) {
    var ids = Array.isArray(enabledIds) ? enabledIds : []
    if (ids.indexOf(configuredDefault) >= 0)
        return configuredDefault
    return ids.length > 0 ? ids[0] : ""
}

function hostMatches(host, list) {
    if (typeof host !== "string" || host === "" || !Array.isArray(list))
        return false
    var normalized = host.toLowerCase()
    if (normalized.charAt(normalized.length - 1) === ".")
        normalized = normalized.slice(0, -1)
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

// Minimal parser: {scheme, host} or null when malformed. Hosts must be plain
// DNS names; user info, backslashes and odd characters are treated as hostile.
function parseUrl(value) {
    var text = String(value === undefined || value === null ? "" : value)
    var schemeMatch = /^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/.exec(text)
    if (!schemeMatch)
        return null
    var scheme = schemeMatch[1].toLowerCase()
    var rest = schemeMatch[2]
    if (scheme !== "https" && scheme !== "http")
        return { scheme: scheme, host: "" }
    if (rest.indexOf("//") !== 0)
        return null
    var authority = rest.slice(2).split(/[\/?#]/)[0]
    if (authority === "" || /[@\\\s%]/.test(authority))
        return null
    var hostMatch = /^([A-Za-z0-9.\-]+)(:[0-9]{1,5})?$/.exec(authority)
    if (!hostMatch)
        return null
    var host = hostMatch[1].toLowerCase()
    if (host.charAt(0) === "." || host.indexOf("..") >= 0)
        return null
    return { scheme: scheme, host: host }
}

function isAboutBlank(value) {
    return String(value === undefined || value === null ? "" : value)
        .toLowerCase() === "about:blank"
}

function isHttpsUrl(value) {
    var parsed = parseUrl(value)
    return parsed !== null && parsed.scheme === "https" && parsed.host !== ""
}

function knownHost(site, host) {
    return hostMatches(host, site.site_hosts) || hostMatches(host, site.auth_hosts)
}

// "allow" | "external" | "block" for a WebEngine navigation request.
function classifyNavigation(request) {
    var info = request || {}
    // Only an explicit subframe is let through; missing info is blocked.
    if (info.isMainFrame === false)
        return "allow"
    var site = byId(info.siteId)
    if (!site)
        return "block"
    if (isAboutBlank(info.url))
        return "allow"
    if (!isHttpsUrl(info.url))
        return "block"
    if (info.linkClicked && !knownHost(site, parseUrl(info.url).host))
        return "external"
    return "allow"
}

// "overlay" | "external" | "block" for a new-window request.
function classifyNewWindow(request) {
    var info = request || {}
    var site = byId(info.siteId)
    if (!site)
        return "block"
    var url = info.url === undefined || info.url === null ? "" : String(info.url)
    var https = isHttpsUrl(url)
    if (info.isDialog && (https || url === "" || isAboutBlank(url)))
        return "overlay"
    if (!https)
        return "block"
    if (hostMatches(parseUrl(url).host, site.auth_hosts))
        return "overlay"
    return "external"
}

// Drops only the QtWebEngine/x.y.z product token; Chrome/platform stay intact.
function userAgent(defaultUa) {
    if (typeof defaultUa !== "string")
        return ""
    return defaultUa.replace(/\s*QtWebEngine\/\S+/g, "")
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
