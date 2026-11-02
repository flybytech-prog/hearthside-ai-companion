import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// UsageView with provider text that tries to be markup: every name, plan,
// caption, error and amount from the helper is shown literally, as plain
// text, so a reply can't make the widget load an image or a link.
TestCase {
    id: testCase
    name: "UsageView"
    width: 500
    height: 700
    visible: true
    when: windowShown

    // Plasma injects i18n(); a stand-in that fills %1, %2...
    function i18n(text) {
        var result = text
        for (var index = 1; index < arguments.length; index++)
            result = result.replace("%" + index, String(arguments[index]))
        return result
    }

    function i18np(singular, plural, count) {
        return (count === 1 ? singular : plural).replace("%1", String(count))
    }

    // Port 9 on this computer: nothing listens, and the test never loads it.
    readonly property string marker: "<img src=\"http://127.0.0.1:9/beacon.png\"><b>Pro</b> &amp;"

    // What main.qml provides as `root`.
    Item {
        id: root
        width: testCase.width
        height: testCase.height
        property bool hasData: true
        property string lastError: ""
        property var snapshot: ({})
        property bool expanded: true
        property string usageMode: "used"
        function providerIconSource(providerId) { return "" }
        function displayedPercent(value) { return value }
        function valueColor(value) { return "black" }
        function barColor(value) { return "black" }

        UsageView {
            id: usage
            anchors.fill: parent
        }
    }

    Text {
        id: reference
        visible: false
    }

    function hostileSnapshot(status) {
        return {
            installed_provider_ids: ["cursor"],
            providers: [{
                provider_id: "cursor",
                display_name: testCase.marker,
                plan: testCase.marker,
                status: status,
                error_message: testCase.marker,
                windows: [{ caption: testCase.marker, used_percent: 40, resets_at: null }],
                billing_usage: { kind: "flex_credit_balance", remaining_credits: testCase.marker, usd_value: 1 }
            }]
        }
    }

    function collect(item, out) {
        if (!item || out.indexOf(item) >= 0)
            return
        out.push(item)
        var kids = item.children || []
        for (var index = 0; index < kids.length; index++)
            collect(kids[index], out)
        if (item.contentItem)
            collect(item.contentItem, out)
    }

    // Shown text items whose text carries the marker.
    function markedItems() {
        var items = []
        collect(usage, items)
        return items.filter(function (item) {
            return typeof item.text === "string" && item.text.indexOf("<img") >= 0
                && item.textFormat !== undefined && item.visible
        })
    }

    function init() {
        root.hasData = true
        root.lastError = ""
        root.snapshot = ({})
    }

    function test_providerTextIsPlain() {
        root.snapshot = hostileSnapshot("error")
        wait(20)
        var marked = markedItems()
        // Name, plan, error, caption and credit amount.
        verify(marked.length >= 5, "found " + marked.length)
        for (var index = 0; index < marked.length; index++)
            compare(marked[index].textFormat, Text.PlainText, "rich text at " + marked[index] + ": " + marked[index].text)
    }

    function test_staleReadingIsPlainToo() {
        root.snapshot = hostileSnapshot("stale")
        wait(20)
        var marked = markedItems()
        verify(marked.length >= 5, "found " + marked.length)
        for (var index = 0; index < marked.length; index++)
            compare(marked[index].textFormat, Text.PlainText)
    }

    // The plan name is laid out as the literal characters "<img src=...>",
    // as wide as plain text, not as an image plus a bold "Pro".
    function test_planNameIsShownLiterally() {
        root.snapshot = hostileSnapshot("ok")
        wait(20)
        var plan = null
        var items = markedItems()
        for (var index = 0; index < items.length; index++) {
            if (items[index].text === testCase.marker && items[index].opacity < 0.7)
                plan = items[index]
        }
        verify(plan !== null, "plan label not found")
        compare(plan.textFormat, Text.PlainText)
        reference.font = plan.font
        reference.textFormat = Text.PlainText
        reference.text = testCase.marker
        var plainWidth = reference.implicitWidth
        // (Without the <img>: rich text would really fetch it.)
        reference.text = testCase.marker.replace(/<img[^>]*>/, "")
        reference.textFormat = Text.RichText
        var richWidth = reference.implicitWidth
        verify(plainWidth > richWidth, "the reference must tell the formats apart")
        compare(plan.implicitWidth, plainWidth)
    }

    // A helper error without data: shown in a plain label, not the
    // placeholder's rich-text explanation.
    function test_helperErrorIsPlain() {
        root.hasData = false
        root.lastError = testCase.marker
        wait(20)
        var marked = markedItems()
        compare(marked.length, 1)
        compare(marked[0].textFormat, Text.PlainText)
        compare(marked[0].text, testCase.marker)
    }
}
