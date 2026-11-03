.pragma library

// Usage alerts: pure rules, no QML state. main.qml keeps the state in memory
// only and passes it back in with every refresh; a Plasma restart starts
// from nothing, so the first reading is always a baseline.
//
// state:    {"<providerId>/<metricId>": {left, resetsAtMs, low}}
// readings: [{providerId, metricId, usedPercent, resetsAtMs}], fresh
//           percentage windows only (failed or stale providers are left out)
// settings: {lowEnabled, lowPercent, resetEnabled}; lowPercent is percent
//           left, whatever the popup's Left/Used shows
//
// "low" fires once when left goes from above the threshold to at or below
// it, and re-arms when left goes back above. "reset" fires when used drops
// and the reset time moved forward by an hour or more, or a known reset
// time is gone (some providers report none for a fresh period); only for a
// window that was at or below the threshold before. A window without a
// reading keeps its old state and never alerts.

var RESET_MIN_MS = 3600000

function keyOf(providerId, metricId) {
    return providerId + "/" + metricId
}

function validReading(reading) {
    return !!reading && typeof reading === "object"
        && typeof reading.providerId === "string" && reading.providerId !== ""
        && typeof reading.metricId === "string" && reading.metricId !== ""
        && typeof reading.usedPercent === "number" && isFinite(reading.usedPercent)
}

function threshold(settings) {
    var value = settings ? settings.lowPercent : undefined
    return typeof value === "number" && isFinite(value) && value > 0 && value < 100 ? value : 20
}

function finiteOrNull(value) {
    return typeof value === "number" && isFinite(value) ? value : null
}

function evaluate(state, readings, settings) {
    var previous = state && typeof state === "object" ? state : {}
    var next = {}
    for (var key in previous) {
        if (Object.prototype.hasOwnProperty.call(previous, key))
            next[key] = previous[key]
    }
    var limit = threshold(settings)
    var lowEnabled = !!settings && settings.lowEnabled === true
    var resetEnabled = !!settings && settings.resetEnabled === true
    var alerts = []
    var list = Array.isArray(readings) ? readings : []
    for (var index = 0; index < list.length; index++) {
        var reading = list[index]
        if (!validReading(reading))
            continue
        var id = keyOf(reading.providerId, reading.metricId)
        var used = Math.max(0, Math.min(100, reading.usedPercent))
        var left = 100 - used
        var resetsAt = finiteOrNull(reading.resetsAtMs)
        var old = Object.prototype.hasOwnProperty.call(previous, id) ? previous[id] : null
        if (!old || typeof old !== "object" || typeof old.left !== "number") {
            // Baseline: a window already low at start never alerts.
            next[id] = { left: left, resetsAtMs: resetsAt, low: left <= limit }
            continue
        }
        var low = old.low === true
        var oldReset = finiteOrNull(old.resetsAtMs)
        var wasReset = oldReset !== null
            && (resetsAt === null || resetsAt - oldReset >= RESET_MIN_MS) && left > old.left
        if (resetEnabled && old.left <= limit && wasReset) {
            alerts.push({ kind: "reset", providerId: reading.providerId,
                          metricId: reading.metricId, left: Math.round(left) })
        }
        if (left > limit) {
            low = false
        } else if (!low && lowEnabled) {
            low = true
            alerts.push({ kind: "low", providerId: reading.providerId,
                          metricId: reading.metricId, left: Math.round(left) })
        }
        // A reading without a reset time keeps the last one known, unless
        // the period just started over.
        next[id] = { left: left, resetsAtMs: resetsAt !== null || wasReset ? resetsAt : oldReset, low: low }
    }
    return { state: next, alerts: alerts }
}
