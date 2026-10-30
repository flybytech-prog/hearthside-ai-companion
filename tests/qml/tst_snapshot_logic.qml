import QtQuick
import QtTest
import "../../plasmoid/contents/ui/SnapshotLogic.js" as SnapshotLogic

TestCase {
    name: "SnapshotLogic"

    readonly property string retryIso: "2030-01-01T00:00:00Z"

    function okResult(providerId, used) {
        return {
            provider_id: providerId,
            status: "ok",
            windows: [{kind: "weekly", used_percent: used}]
        }
    }

    function failure(providerId, kind, retryAt) {
        return {
            provider_id: providerId,
            status: kind === "rate_limited" ? "rate_limited" : "error",
            failure_kind: kind,
            error_message: "Message for " + kind,
            retry_at: retryAt === undefined ? null : retryAt,
            windows: []
        }
    }

    function test_preservesLastGood() {
        verify(SnapshotLogic.preservesLastGood("transient"))
        verify(SnapshotLogic.preservesLastGood("rate_limited"))
        verify(SnapshotLogic.preservesLastGood("invalid_response"))
        verify(!SnapshotLogic.preservesLastGood("authentication"))
        verify(!SnapshotLogic.preservesLastGood("storage"))
        verify(!SnapshotLogic.preservesLastGood(undefined))
    }

    function test_okStoresStateAndClearsCooldown() {
        var merged = SnapshotLogic.mergeResults({}, {}, {"claude": 123}, [okResult("claude", 40)])
        compare(merged.states.claude.status, "ok")
        compare(merged.states.claude.stale, false)
        compare(merged.goods.claude.windows[0].used_percent, 40)
        verify(!("claude" in merged.cooldowns))
    }

    function test_preservingFailureWithLastGoodIsStale() {
        var kinds = ["transient", "rate_limited", "invalid_response"]
        for (var index = 0; index < kinds.length; index++) {
            var kind = kinds[index]
            var good = SnapshotLogic.mergeResults({}, {}, {}, [okResult("codex", 25)])
            var merged = SnapshotLogic.mergeResults(
                good.states, good.goods, good.cooldowns,
                [failure("codex", kind, kind === "rate_limited" ? retryIso : null)]
            )
            var state = merged.states.codex
            compare(state.status, "stale", kind)
            compare(state.stale, true, kind)
            compare(state.windows.length, 1, kind)
            compare(state.windows[0].used_percent, 25, kind)
            compare(state.error_message, "Message for " + kind, kind)
            compare(state.failure_kind, kind, kind)
            compare(state.retry_at, kind === "rate_limited" ? retryIso : null, kind)
            compare(merged.goods.codex.status, "ok", kind)
        }
    }

    function test_preservingFailureWithoutLastGoodShowsFailure() {
        var goods = {"claude": okResult("claude", 10)}
        var merged = SnapshotLogic.mergeResults({}, goods, {}, [failure("codex", "transient")])
        compare(merged.states.codex.status, "error")
        compare(merged.states.codex.stale, false)
        compare(merged.states.codex.failure_kind, "transient")
        verify(!("codex" in merged.goods))
        compare(merged.goods.claude, goods.claude)
    }

    function test_nonPreservingFailureDropsLastGood() {
        var kinds = ["authentication", "storage"]
        for (var index = 0; index < kinds.length; index++) {
            var good = SnapshotLogic.mergeResults({}, {}, {}, [okResult("grok", 5)])
            var merged = SnapshotLogic.mergeResults(
                good.states, good.goods, good.cooldowns, [failure("grok", kinds[index])]
            )
            compare(merged.states.grok.status, "error", kinds[index])
            compare(merged.states.grok.stale, false, kinds[index])
            verify(!("grok" in merged.goods), kinds[index])
        }
    }

    function test_rateLimitCooldown() {
        var merged = SnapshotLogic.mergeResults({}, {}, {}, [failure("cursor", "rate_limited", retryIso)])
        compare(merged.cooldowns.cursor, new Date(retryIso).getTime())

        var invalid = SnapshotLogic.mergeResults({}, {}, {}, [failure("cursor", "rate_limited", "not a date")])
        verify(!("cursor" in invalid.cooldowns))

        var missing = SnapshotLogic.mergeResults({}, {}, {}, [failure("cursor", "rate_limited", null)])
        verify(!("cursor" in missing.cooldowns))

        var transient = SnapshotLogic.mergeResults({}, {}, {}, [failure("cursor", "transient", retryIso)])
        verify(!("cursor" in transient.cooldowns))
    }

    function test_inputsAreNotMutated() {
        var goodResult = okResult("claude", 30)
        var states = {"claude": goodResult}
        var goods = {"claude": goodResult}
        var cooldowns = {"codex": 99}
        var results = [okResult("codex", 50), failure("claude", "authentication"),
                       failure("grok", "rate_limited", retryIso)]
        var snapshot = JSON.stringify([states, goods, cooldowns, results])

        var merged = SnapshotLogic.mergeResults(states, goods, cooldowns, results)

        compare(JSON.stringify([states, goods, cooldowns, results]), snapshot)
        verify(!("stale" in results[0]))
        verify(merged.states !== states)
        verify(merged.goods !== goods)
        verify(merged.cooldowns !== cooldowns)
        verify(merged.states.codex !== results[0])
    }

    function test_malformedResultsIgnored() {
        var merged = SnapshotLogic.mergeResults({}, {}, {}, [null, 7, {status: "ok"}])
        compare(Object.keys(merged.states).length, 0)
        compare(Object.keys(SnapshotLogic.mergeResults(null, null, null, null).states).length, 0)
    }

    function test_windowFor() {
        var data = okResult("claude", 12)
        compare(SnapshotLogic.windowFor(data, "weekly").used_percent, 12)
        compare(SnapshotLogic.windowFor(data, "session"), null)
        compare(SnapshotLogic.windowFor(null, "weekly"), null)
    }

    function test_percentReading() {
        var data = okResult("claude", 30)
        var left = SnapshotLogic.metricReading(data, "weekly", "remaining")
        compare(left.type, "percentage")
        compare(left.raw_used, 30)
        compare(left.value, 70)
        compare(SnapshotLogic.metricReading(data, "weekly", "used").value, 30)
        compare(SnapshotLogic.metricReading(okResult("claude", 140), "weekly", "remaining").value, 0)
        compare(SnapshotLogic.metricReading(okResult("claude", -10), "weekly", "remaining").value, 100)
        compare(SnapshotLogic.displayedPercent(140, "used"), 140)
    }

    function test_boundedSpendReading() {
        var data = {billing_usage: {kind: "bounded_spend", used_amount: 30, limit_amount: 50}}
        var left = SnapshotLogic.metricReading(data, "extra_usage", "remaining")
        compare(left.type, "money")
        compare(left.value, 20)
        compare(left.currency, "USD")
        compare(SnapshotLogic.metricReading(data, "extra_usage", "used").value, 30)
        var over = {billing_usage: {kind: "bounded_spend", used_amount: 80, limit_amount: 50}}
        compare(SnapshotLogic.metricReading(over, "extra_usage", "remaining").value, 0)
    }

    function test_unboundedSpendIgnoresMode() {
        var data = {billing_usage: {kind: "unbounded_spend", used_amount: 12.5, currency_code: "EUR"}}
        compare(SnapshotLogic.metricReading(data, "extra_usage", "remaining").value, 12.5)
        compare(SnapshotLogic.metricReading(data, "extra_usage", "used").value, 12.5)
        compare(SnapshotLogic.metricReading(data, "extra_usage", "used").currency, "EUR")
    }

    function test_creditsReading() {
        var data = {billing_usage: {kind: "flex_credit_balance", remaining_credits: 420, usd_value: 4.2}}
        var reading = SnapshotLogic.metricReading(data, "credits", "remaining")
        compare(reading.type, "credits")
        compare(reading.value, 420)
        compare(reading.usd, 4.2)
        compare(SnapshotLogic.metricReading(data, "extra_usage", "remaining"), null)
    }

    function test_unknownMetricIsNull() {
        compare(SnapshotLogic.metricReading(okResult("claude", 30), "nope", "remaining"), null)
        compare(SnapshotLogic.metricReading(null, "weekly", "used"), null)
    }

    function test_millisUntil() {
        var now = new Date("2030-01-01T00:00:00Z").getTime()
        compare(SnapshotLogic.millisUntil("2030-01-01T00:05:00Z", now), 300000)
        compare(SnapshotLogic.millisUntil("2030-01-01T00:00:00Z", now), 0)
        compare(SnapshotLogic.millisUntil("2029-12-31T23:59:00Z", now), -60000)
        compare(SnapshotLogic.millisUntil("not a date", now), null)
        compare(SnapshotLogic.millisUntil("", now), null)
        compare(SnapshotLogic.millisUntil(null, now), null)
        compare(SnapshotLogic.millisUntil(undefined, now), null)
        compare(SnapshotLogic.millisUntil("2030-01-01T00:05:00Z", NaN), null)
    }
}
