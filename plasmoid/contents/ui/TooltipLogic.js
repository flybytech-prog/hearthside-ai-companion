.pragma library

// The panel icon's hover tooltip: pure rules, no QML state. main.qml and
// configGeneral.qml pass the catalog, the settings and the clock in, and do
// the translating; nothing here reads the configuration.
//
// tooltipMetrics: "" (or anything unreadable) means "same as the Usage tab".
// Otherwise a JSON object {providerId: [metricIds]}: a provider listed with
// an empty array is left out of the tooltip, a provider not listed shows what
// the Usage tab shows.

var MINUTE_MS = 60000

function metricIdsOf(providers, providerId) {
    var list = Array.isArray(providers) ? providers : []
    for (var index = 0; index < list.length; index++) {
        var provider = list[index]
        if (provider && provider.provider_id === providerId && Array.isArray(provider.metrics))
            return provider.metrics.map(function (metric) { return metric ? metric.id : "" })
    }
    return null
}

// Known metric ids of one provider, in catalog order, without duplicates.
function cleanMetricList(providers, providerId, wanted) {
    var known = metricIdsOf(providers, providerId)
    if (!known || !Array.isArray(wanted))
        return null
    return known.filter(function (metricId) {
        return metricId !== "" && wanted.indexOf(metricId) >= 0
    })
}

// null for "same as the Usage tab", else {providerId: [metricIds]} with only
// catalog providers and metrics.
function parseTooltipMetrics(value, providers) {
    if (typeof value !== "string" || value === "")
        return null
    var parsed
    try {
        parsed = JSON.parse(value)
    } catch (error) {
        return null
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        return null
    var result = {}
    for (var providerId in parsed) {
        if (!Object.prototype.hasOwnProperty.call(parsed, providerId))
            continue
        var clean = cleanMetricList(providers, providerId, parsed[providerId])
        if (clean)
            result[providerId] = clean
    }
    return result
}

// The Usage tab's choice as a full custom map: each catalog provider with its
// checked metrics, else its default metric. Turning "Same as the Usage tab"
// off starts from this, so the tooltip doesn't change until a box is toggled.
function seedTooltipMetrics(providerMetricsValue, providers) {
    var usage = {}
    try {
        var parsed = JSON.parse(providerMetricsValue || "")
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
            usage = parsed
    } catch (error) {
    }
    var result = {}
    var list = Array.isArray(providers) ? providers : []
    for (var index = 0; index < list.length; index++) {
        var provider = list[index]
        if (!provider || typeof provider.provider_id !== "string")
            continue
        var chosen = cleanMetricList(providers, provider.provider_id, usage[provider.provider_id]) || []
        if (chosen.length === 0)
            chosen = cleanMetricList(providers, provider.provider_id, [provider.default_metric]) || []
        result[provider.provider_id] = chosen
    }
    return result
}

// Ticks or unticks one metric; returns a new map, metrics in catalog order.
function setTooltipMetric(choice, providers, providerId, metricId, enabled) {
    var result = Object.assign({}, choice || {})
    var current = Array.isArray(result[providerId]) ? result[providerId].slice() : []
    var at = current.indexOf(metricId)
    if (enabled && at < 0)
        current.push(metricId)
    else if (!enabled && at >= 0)
        current.splice(at, 1)
    var clean = cleanMetricList(providers, providerId, current)
    if (clean)
        result[providerId] = clean
    return result
}

function isChosen(choice, providerId, metricId) {
    var list = choice && Array.isArray(choice[providerId]) ? choice[providerId] : []
    return list.indexOf(metricId) >= 0
}

// The Usage tab's groups ({provider_id, metrics, ...}) with the tooltip's own
// metrics. Groups left without metrics are dropped. Never mutates the input.
function applyChoice(groups, choice) {
    var list = Array.isArray(groups) ? groups : []
    if (!choice)
        return list.slice()
    var result = []
    for (var index = 0; index < list.length; index++) {
        var group = list[index]
        if (!group)
            continue
        var metrics = Array.isArray(choice[group.provider_id]) ? choice[group.provider_id] : group.metrics
        if (!Array.isArray(metrics) || metrics.length === 0)
            continue
        result.push(Object.assign({}, group, {metrics: metrics.slice()}))
    }
    return result
}

// The reset time as parts for the caller to translate, or null when it is
// unknown. kind: "now", "minutes" {minutes}, "hours" {hours, minutes} or
// "days" {days}; "days" also means the caller adds the weekday and time.
function resetPhrase(resetsAtMs, nowMs) {
    var target = Number(resetsAtMs)
    var now = Number(nowMs)
    if (resetsAtMs === null || resetsAtMs === undefined || resetsAtMs === ""
            || !isFinite(target) || !isFinite(now))
        return null
    var difference = target - now
    if (difference <= 0)
        return {kind: "now"}
    var minutes = Math.max(1, Math.round(difference / MINUTE_MS))
    if (minutes < 60)
        return {kind: "minutes", minutes: minutes}
    var hours = Math.floor(minutes / 60)
    if (hours < 24)
        return {kind: "hours", hours: hours, minutes: minutes % 60}
    return {kind: "days", days: Math.floor(hours / 24)}
}

// groups: [{name, items: [{title, value, reset}]}], already translated text;
// reset is "" when unknown or not shown. With showsReset every reading gets
// its own line, else one line per provider.
function tooltipLines(groups, options) {
    var list = Array.isArray(groups) ? groups : []
    var showsReset = !!(options && options.showsReset)
    var lines = []
    for (var groupIndex = 0; groupIndex < list.length; groupIndex++) {
        var group = list[groupIndex]
        var items = group && Array.isArray(group.items)
            ? group.items.filter(function (entry) { return !!entry && typeof entry === "object" }) : []
        if (items.length === 0)
            continue
        var name = String(group.name || "")
        if (showsReset) {
            for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
                var item = items[itemIndex]
                var reset = item.reset ? ", " + item.reset : ""
                lines.push(name + " — " + item.title + ": " + item.value + reset)
            }
        } else {
            lines.push(name + ": " + items.map(function (entry) {
                return entry.title + " " + entry.value
            }).join(" · "))
        }
    }
    return lines
}
