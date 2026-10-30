.pragma library

// Pure snapshot rules shared by main.qml and the Qt Quick tests. Nothing here
// touches QML state; callers pass everything in and assign the results.

// Failures that keep showing the last good reading instead of clearing it.
function preservesLastGood(failureKind) {
    return failureKind === "transient"
        || failureKind === "rate_limited"
        || failureKind === "invalid_response"
}

// Merges one helper run into the per-provider maps. Returns fresh copies and
// never mutates the arguments or the result objects they contain.
function mergeResults(states, goods, cooldowns, results) {
    var nextStates = Object.assign({}, states || {})
    var nextGoods = Object.assign({}, goods || {})
    var nextCooldowns = Object.assign({}, cooldowns || {})
    var list = Array.isArray(results) ? results : []
    for (var index = 0; index < list.length; index++) {
        var current = list[index]
        if (!current || typeof current !== "object")
            continue
        var providerId = current.provider_id
        if (typeof providerId !== "string" || providerId === "")
            continue
        if (current.status === "ok") {
            var fresh = Object.assign({}, current, {stale: false})
            nextStates[providerId] = fresh
            nextGoods[providerId] = fresh
            delete nextCooldowns[providerId]
            continue
        }
        var preserves = preservesLastGood(current.failure_kind)
        if (preserves && nextGoods[providerId]) {
            nextStates[providerId] = Object.assign({}, nextGoods[providerId], {
                status: "stale",
                stale: true,
                failure_kind: current.failure_kind,
                error_message: current.error_message,
                retry_at: current.retry_at
            })
        } else {
            nextStates[providerId] = Object.assign({}, current, {stale: false})
            if (!preserves)
                delete nextGoods[providerId]
        }
        if (current.failure_kind === "rate_limited" && current.retry_at) {
            var retryMs = new Date(current.retry_at).getTime()
            if (isFinite(retryMs))
                nextCooldowns[providerId] = retryMs
        }
    }
    return {states: nextStates, goods: nextGoods, cooldowns: nextCooldowns}
}

function windowFor(providerData, metricId) {
    var windows = providerData && Array.isArray(providerData.windows)
        ? providerData.windows : []
    for (var index = 0; index < windows.length; index++) {
        if (windows[index] && windows[index].kind === metricId)
            return windows[index]
    }
    return null
}

function displayedPercent(rawUsed, usageMode) {
    if (usageMode === "used")
        return rawUsed
    return 100 - Math.max(0, Math.min(100, rawUsed))
}

function metricReading(providerData, metricId, usageMode) {
    var window = windowFor(providerData, metricId)
    if (window) {
        return {
            type: "percentage",
            raw_used: Number(window.used_percent),
            value: displayedPercent(Number(window.used_percent), usageMode)
        }
    }
    var billing = providerData ? providerData.billing_usage : null
    if (!billing)
        return null
    if (metricId === "extra_usage"
            && (billing.kind === "bounded_spend"
                || billing.kind === "unbounded_spend")) {
        var amount = Number(billing.used_amount || 0)
        if (usageMode !== "used" && billing.kind === "bounded_spend")
            amount = Math.max(Number(billing.limit_amount || 0) - amount, 0)
        return {
            type: "money",
            value: amount,
            currency: billing.currency_code || "USD"
        }
    }
    if (metricId === "credits" && billing.kind === "flex_credit_balance") {
        return {
            type: "credits",
            value: Number(billing.remaining_credits || 0),
            usd: Number(billing.usd_value || 0)
        }
    }
    return null
}

// Milliseconds from nowMs until iso, or null when either value is not a
// usable time. Callers omit the countdown text when this returns null.
function millisUntil(iso, nowMs) {
    if (!iso)
        return null
    var target = new Date(iso).getTime()
    var now = Number(nowMs)
    if (!isFinite(target) || !isFinite(now))
        return null
    return target - now
}
