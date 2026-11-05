import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// The hover popup layout: title, each provider in bold, one reading per
// line; plain text only, so names can't turn into markup.
TestCase {
    name: "UsageTooltip"
    when: windowShown
    width: 400
    height: 400

    Component {
        id: tooltipComponent
        UsageTooltip {}
    }

    function findAll(item, objectName, found) {
        found = found || []
        if (item.objectName === objectName)
            found.push(item)
        for (var index = 0; index < item.children.length; index++)
            findAll(item.children[index], objectName, found)
        return found
    }

    function test_layout() {
        var tip = createTemporaryObject(tooltipComponent, this, {
            title: "Hearthside",
            sections: [
                {name: "Claude Code", items: [{title: "Session", value: "100% left"},
                                              {title: "Weekly", value: "41% left"}]},
                {name: "Codex", items: [{title: "Weekly", value: "80% left"}]}
            ]
        })
        verify(tip)
        var providers = findAll(tip, "tooltipProvider")
        compare(providers.length, 2)
        compare(providers[0].text, "Claude Code")
        verify(providers[0].font.bold)
        compare(providers[0].textFormat, Text.PlainText)
        var titles = findAll(tip, "tooltipReadingTitle")
        var values = findAll(tip, "tooltipReadingValue")
        compare(titles.map(function (label) { return label.text }), ["Session", "Weekly", "Weekly"])
        compare(values.map(function (label) { return label.text }), ["100% left", "41% left", "80% left"])
        values.concat(titles).forEach(function (label) { compare(label.textFormat, Text.PlainText) })
        // Values line up on the right edge, below their provider.
        tryVerify(function () { return tip.implicitWidth > 0 && tip.implicitHeight > 0 })
        var right0 = values[0].mapToItem(tip, values[0].width, 0).x
        var right1 = values[1].mapToItem(tip, values[1].width, 0).x
        fuzzyCompare(right0, right1, 1)
        verify(values[0].mapToItem(tip, 0, 0).y > providers[0].mapToItem(tip, 0, 0).y)
        verify(values[1].mapToItem(tip, 0, 0).y > values[0].mapToItem(tip, 0, 0).y)
    }

    function test_markupStaysText() {
        var tip = createTemporaryObject(tooltipComponent, this, {
            sections: [{name: "<b>x</b>", items: [{title: "<img src=a>", value: "1%"}]}]
        })
        var providers = findAll(tip, "tooltipProvider")
        compare(providers[0].text, "<b>x</b>")
        compare(providers[0].textFormat, Text.PlainText)
    }

    function test_empty() {
        var tip = createTemporaryObject(tooltipComponent, this, {sections: []})
        compare(findAll(tip, "tooltipProvider").length, 0)
    }
}
