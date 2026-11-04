import QtQuick
import QtTest
import "../../plasmoid/contents/ui/ProviderCatalog.js" as Catalog
import "../../plasmoid/contents/ui/TooltipLogic.js" as TooltipLogic

TestCase {
    name: "TooltipLogic"

    readonly property double minute: 60000
    readonly property double hour: 3600000

    function test_emptyOrOddMeansSameAsUsageTab() {
        compare(TooltipLogic.parseTooltipMetrics("", Catalog.providers), null)
        compare(TooltipLogic.parseTooltipMetrics(undefined, Catalog.providers), null)
        compare(TooltipLogic.parseTooltipMetrics("{", Catalog.providers), null)
        compare(TooltipLogic.parseTooltipMetrics("[\"claude\"]", Catalog.providers), null)
        compare(TooltipLogic.parseTooltipMetrics("null", Catalog.providers), null)
        compare(TooltipLogic.parseTooltipMetrics("7", Catalog.providers), null)
    }

    function test_parseKeepsCatalogIdsInCatalogOrder() {
        var parsed = TooltipLogic.parseTooltipMetrics(
            "{\"claude\":[\"weekly\",\"session\",\"session\",\"daily\",5],\"nope\":[\"weekly\"],"
            + "\"codex\":\"weekly\",\"grok\":[]}", Catalog.providers)
        compare(parsed, {claude: ["session", "weekly"], grok: []})
    }

    function test_claudeSessionIsSelectable() {
        var parsed = TooltipLogic.parseTooltipMetrics("{\"claude\":[\"session\"]}", Catalog.providers)
        compare(parsed.claude, ["session"])
        var next = TooltipLogic.setTooltipMetric(parsed, Catalog.providers, "claude", "weekly", true)
        compare(next.claude, ["session", "weekly"])
        compare(parsed.claude, ["session"])
        verify(TooltipLogic.isChosen(next, "claude", "session"))
        verify(!TooltipLogic.isChosen(next, "claude", "sonnet"))
        verify(!TooltipLogic.isChosen(null, "claude", "session"))
    }

    function test_setTooltipMetricIgnoresUnknownIds() {
        var next = TooltipLogic.setTooltipMetric({}, Catalog.providers, "claude", "daily", true)
        compare(next.claude, [])
        next = TooltipLogic.setTooltipMetric({claude: ["weekly"]}, Catalog.providers, "claude", "weekly", false)
        compare(next.claude, [])
        next = TooltipLogic.setTooltipMetric({}, Catalog.providers, "nope", "weekly", true)
        compare(next, {})
    }

    function test_seedFollowsTheUsageTab() {
        var seed = TooltipLogic.seedTooltipMetrics(
            "{\"claude\":[\"weekly\",\"session\"],\"codex\":[\"bogus\"]}", Catalog.providers)
        compare(seed.claude, ["session", "weekly"])
        compare(seed.codex, ["weekly"])
        compare(seed.cursor, ["total_usage"])
        compare(seed.copilot, ["credits"])
        compare(Object.keys(seed).length, Catalog.providers.length)
        compare(TooltipLogic.seedTooltipMetrics("broken", Catalog.providers).claude, ["weekly"])
    }

    function test_applyChoice() {
        var groups = [
            {provider_id: "claude", metrics: ["weekly"], name: "c"},
            {provider_id: "codex", metrics: ["weekly"]},
            {provider_id: "grok", metrics: ["weekly"]}
        ]
        compare(TooltipLogic.applyChoice(groups, null), groups)
        var applied = TooltipLogic.applyChoice(groups, {claude: ["session", "weekly"], grok: []})
        compare(applied.length, 2)
        compare(applied[0], {provider_id: "claude", metrics: ["session", "weekly"], name: "c"})
        // Not listed: what the Usage tab shows.
        compare(applied[1].metrics, ["weekly"])
        compare(groups[0].metrics, ["weekly"])
        compare(TooltipLogic.applyChoice(undefined, {}), [])
    }

    function test_resetPhrase() {
        var now = 1000 * hour
        compare(TooltipLogic.resetPhrase(null, now), null)
        compare(TooltipLogic.resetPhrase(undefined, now), null)
        compare(TooltipLogic.resetPhrase(NaN, now), null)
        compare(TooltipLogic.resetPhrase("", now), null)
        compare(TooltipLogic.resetPhrase(now + hour, NaN), null)
        compare(TooltipLogic.resetPhrase(now, now), {kind: "now"})
        compare(TooltipLogic.resetPhrase(now - minute, now), {kind: "now"})
        compare(TooltipLogic.resetPhrase(now + 10000, now), {kind: "minutes", minutes: 1})
        compare(TooltipLogic.resetPhrase(now + 45 * minute, now), {kind: "minutes", minutes: 45})
        compare(TooltipLogic.resetPhrase(now + 2 * hour + 10 * minute, now), {kind: "hours", hours: 2, minutes: 10})
        compare(TooltipLogic.resetPhrase(now + 3 * hour, now), {kind: "hours", hours: 3, minutes: 0})
        compare(TooltipLogic.resetPhrase(now + 23 * hour + 59 * minute, now), {kind: "hours", hours: 23, minutes: 59})
        compare(TooltipLogic.resetPhrase(now + 24 * hour, now), {kind: "days", days: 1})
        compare(TooltipLogic.resetPhrase(now + 3 * 24 * hour + 5 * hour, now), {kind: "days", days: 3})
    }

    function test_linesWithReset() {
        var groups = [{name: "Claude Code", items: [
            {title: "Session", value: "62% left", reset: "resets in 2 h 10 min"},
            {title: "Weekly", value: "80% left", reset: ""}
        ]}]
        compare(TooltipLogic.tooltipLines(groups, {showsReset: true}), [
            "Claude Code — Session: 62% left, resets in 2 h 10 min",
            "Claude Code — Weekly: 80% left"
        ])
    }

    function test_linesWithoutReset() {
        var groups = [
            {name: "Claude Code", items: [
                {title: "Session", value: "38% used", reset: "ignored"},
                {title: "Weekly", value: "20% used", reset: ""}
            ]},
            {name: "Codex", items: []},
            null
        ]
        compare(TooltipLogic.tooltipLines(groups, {showsReset: false}),
                ["Claude Code: Session 38% used · Weekly 20% used"])
        compare(TooltipLogic.tooltipLines(groups), ["Claude Code: Session 38% used · Weekly 20% used"])
        compare(TooltipLogic.tooltipLines(undefined, {showsReset: true}), [])
    }
}
