import QtQuick
import QtTest
import "../../plasmoid/contents/ui/AlertLogic.js" as AlertLogic

TestCase {
    name: "AlertLogic"

    readonly property double hour: 3600000
    readonly property var on: ({lowEnabled: true, lowPercent: 20, resetEnabled: true})

    function reading(used, resetsAtMs, metricId) {
        return {providerId: "claude", metricId: metricId || "weekly", usedPercent: used,
                resetsAtMs: resetsAtMs === undefined ? 1000 * hour : resetsAtMs}
    }

    // Runs the readings one refresh at a time; returns every refresh's alerts.
    function run(steps, settings) {
        var state = {}
        var all = []
        for (var index = 0; index < steps.length; index++) {
            var result = AlertLogic.evaluate(state, steps[index], settings || on)
            state = result.state
            all.push(result.alerts)
        }
        return {state: state, alerts: all}
    }

    function test_firstReadingIsABaseline() {
        // Already low at start: never alerts until it goes back above.
        var result = run([[reading(95)], [reading(96)]])
        compare(result.alerts, [[], []])
        compare(result.state["claude/weekly"].low, true)
    }

    function test_lowFiresOnceWhenCrossing() {
        var result = run([[reading(50)], [reading(79)], [reading(80)], [reading(85)], [reading(90)]])
        compare(result.alerts[0], [])
        compare(result.alerts[1], [])
        compare(result.alerts[2], [{kind: "low", providerId: "claude", metricId: "weekly", left: 20}])
        compare(result.alerts[3], [])
        compare(result.alerts[4], [])
    }

    function test_lowRearmsAboveTheThreshold() {
        var result = run([[reading(50)], [reading(85)], [reading(70)], [reading(81.4)]])
        compare(result.alerts[1].length, 1)
        compare(result.alerts[2], [])
        compare(result.alerts[3], [{kind: "low", providerId: "claude", metricId: "weekly", left: 19}])
    }

    function test_thresholdIsPercentLeft() {
        var settings = {lowEnabled: true, lowPercent: 50, resetEnabled: false}
        var result = run([[reading(40)], [reading(55)]], settings)
        compare(result.alerts[1], [{kind: "low", providerId: "claude", metricId: "weekly", left: 45}])
        // Odd thresholds mean 20.
        result = run([[reading(10)], [reading(81)]], {lowEnabled: true, lowPercent: "50"})
        compare(result.alerts[1].length, 1)
        result = run([[reading(10)], [reading(81)]], {lowEnabled: true, lowPercent: 0})
        compare(result.alerts[1].length, 1)
    }

    function test_raisingTheThresholdAlertsOnce() {
        // The QA1 check: below 50% left, the threshold moves from 20 to 50.
        var state = AlertLogic.evaluate({}, [reading(60)], on).state
        var result = AlertLogic.evaluate(state, [reading(60)], {lowEnabled: true, lowPercent: 50})
        compare(result.alerts, [{kind: "low", providerId: "claude", metricId: "weekly", left: 40}])
        result = AlertLogic.evaluate(result.state, [reading(61)], {lowEnabled: true, lowPercent: 50})
        compare(result.alerts, [])
    }

    function test_disabledLowNeverAlertsButStaysArmed() {
        var off = {lowEnabled: false, lowPercent: 20, resetEnabled: false}
        var result = run([[reading(50)], [reading(90)]], off)
        compare(result.alerts, [[], []])
        compare(result.state["claude/weekly"].low, false)
        // Turned on while low: one alert.
        var next = AlertLogic.evaluate(result.state, [reading(91)], on)
        compare(next.alerts.length, 1)
        compare(next.alerts[0].kind, "low")
    }

    function test_resetFiresOnlyAfterALowWindow() {
        var result = run([[reading(50, 10 * hour)], [reading(85, 10 * hour)], [reading(3, 11 * hour)]])
        compare(result.alerts[1].length, 1)
        compare(result.alerts[2], [{kind: "reset", providerId: "claude", metricId: "weekly", left: 97}])
        compare(result.state["claude/weekly"].low, false)
        // Not low before: no reset alert.
        result = run([[reading(50, 10 * hour)], [reading(3, 11 * hour)]])
        compare(result.alerts[1], [])
    }

    function test_resetNeedsTimeForwardAnHourAndUsedDropping() {
        // Less than an hour forward.
        var result = run([[reading(90, 10 * hour)], [reading(3, 10.5 * hour)]])
        compare(result.alerts[1], [])
        // Used did not drop.
        result = run([[reading(90, 10 * hour)], [reading(95, 12 * hour)]])
        compare(result.alerts[1], [])
        // Time moved back.
        result = run([[reading(90, 10 * hour)], [reading(3, 8 * hour)]])
        compare(result.alerts[1], [])
        // No reset time at all.
        result = run([[reading(90, null)], [reading(3, null)]])
        compare(result.alerts[1], [])
        // Turned off.
        result = run([[reading(90, 10 * hour)], [reading(3, 12 * hour)]],
            {lowEnabled: true, lowPercent: 20, resetEnabled: false})
        compare(result.alerts[1], [])
    }

    function test_resetStillLowDoesNotAlertLowAgain() {
        var result = run([[reading(70, 10 * hour)], [reading(90, 10 * hour)], [reading(85, 12 * hour)]])
        compare(result.alerts[1].length, 1)
        compare(result.alerts[2], [{kind: "reset", providerId: "claude", metricId: "weekly", left: 15}])
    }

    function test_missingReadingsKeepTheState() {
        var state = run([[reading(50)], [reading(85)]]).state
        var result = AlertLogic.evaluate(state, [], on)
        compare(result.alerts, [])
        compare(result.state, state)
        // Odd readings are ignored too.
        var odd = [null, 7, {providerId: "claude", metricId: "weekly", usedPercent: NaN},
                   {providerId: "claude", metricId: "weekly", usedPercent: "90"},
                   {providerId: "", metricId: "weekly", usedPercent: 90},
                   {providerId: "claude", usedPercent: 90}]
        result = AlertLogic.evaluate(state, odd, on)
        compare(result.alerts, [])
        compare(result.state, state)
        result = AlertLogic.evaluate(state, undefined, on)
        compare(result.state, state)
    }

    function test_missingResetTimeKeepsTheLastOne() {
        var result = run([[reading(90, 10 * hour)], [reading(91, null)], [reading(3, 12 * hour)]])
        compare(result.alerts[2].length, 1)
        compare(result.alerts[2][0].kind, "reset")
    }

    function test_windowsAreTrackedSeparately() {
        var result = run([
            [reading(50, undefined, "weekly"), reading(50, undefined, "session")],
            [reading(85, undefined, "weekly"), reading(60, undefined, "session")]
        ])
        compare(result.alerts[1], [{kind: "low", providerId: "claude", metricId: "weekly", left: 15}])
        verify(result.state["claude/session"].low === false)
    }

    function test_usedIsClampedAndArgumentsAreNotChanged() {
        var state = {}
        var first = AlertLogic.evaluate(state, [reading(-10)], on)
        compare(state, {})
        compare(first.state["claude/weekly"].left, 100)
        var second = AlertLogic.evaluate(first.state, [reading(140)], on)
        compare(first.state["claude/weekly"].left, 100)
        compare(second.alerts, [{kind: "low", providerId: "claude", metricId: "weekly", left: 0}])
    }

    function test_oddStateAndSettings() {
        var result = AlertLogic.evaluate(null, [reading(90)], null)
        compare(result.alerts, [])
        result = AlertLogic.evaluate({"claude/weekly": "junk"}, [reading(90)], on)
        compare(result.alerts, [])
        compare(result.state["claude/weekly"].low, true)
        result = AlertLogic.evaluate({"claude/weekly": {left: 90, low: false}}, [reading(90)], {})
        compare(result.alerts, [])
    }

    function test_resetTimeGoneAndUsedDroppedIsAReset() {
        // Low, then the provider reports a fresh period without a reset time.
        var result = run([[reading(50, 10 * hour)], [reading(85, 10 * hour)], [reading(0, null)]])
        compare(result.alerts[1].length, 1)
        compare(result.alerts[2], [{kind: "reset", providerId: "claude", metricId: "weekly", left: 100}])
        // The old reset time is not carried past the reset.
        compare(result.state["claude/weekly"].resetsAtMs, null)
        // Gone but used did not drop: no reset.
        result = run([[reading(90, 10 * hour)], [reading(92, null)]])
        compare(result.alerts[1], [])
        compare(result.state["claude/weekly"].resetsAtMs, 10 * hour)
    }

    function test_noSecondResetFromTheOldTime() {
        // After a reset the next reading with a new reset time is compared
        // with nothing, so it can't count as another reset.
        var result = run([[reading(90, 10 * hour)], [reading(5, null)], [reading(85, null)],
                          [reading(2, 30 * hour)]])
        compare(result.alerts[1].length, 1)
        compare(result.alerts[2].length, 1)
        compare(result.alerts[2][0].kind, "low")
        compare(result.alerts[3], [])
    }
}
