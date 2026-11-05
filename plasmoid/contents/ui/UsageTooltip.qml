import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// The panel icon's hover popup while it shows usage: the title, then each
// provider's name in bold with one reading per line (name left, value
// right). main.qml passes TooltipLogic.tooltipSections(); every text here is
// plain text.
Item {
    id: tip

    property string title: ""
    // [{name, items: [{title, value}]}]
    property var sections: []

    implicitWidth: column.implicitWidth + Kirigami.Units.largeSpacing * 2
    implicitHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2
    Layout.minimumWidth: implicitWidth
    Layout.minimumHeight: implicitHeight
    Layout.maximumWidth: implicitWidth
    Layout.maximumHeight: implicitHeight

    LayoutMirroring.enabled: Application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false

    ColumnLayout {
        id: column
        objectName: "tooltipColumn"
        x: Kirigami.Units.largeSpacing
        y: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            level: 3
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: tip.title
            visible: text !== ""
        }

        Repeater {
            model: tip.sections

            delegate: ColumnLayout {
                id: section
                required property var modelData
                required property int index
                objectName: "tooltipSection"
                Layout.fillWidth: true
                Layout.topMargin: section.index > 0 ? Kirigami.Units.smallSpacing : 0
                spacing: 0

                PlasmaComponents.Label {
                    objectName: "tooltipProvider"
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    font.bold: true
                    text: section.modelData.name
                }

                Repeater {
                    model: section.modelData.items

                    delegate: RowLayout {
                        id: reading
                        required property var modelData
                        objectName: "tooltipReading"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.gridUnit

                        PlasmaComponents.Label {
                            objectName: "tooltipReadingTitle"
                            Layout.fillWidth: true
                            textFormat: Text.PlainText
                            opacity: 0.75
                            text: reading.modelData.title
                        }
                        PlasmaComponents.Label {
                            objectName: "tooltipReadingValue"
                            textFormat: Text.PlainText
                            horizontalAlignment: Text.AlignRight
                            text: reading.modelData.value
                        }
                    }
                }
            }
        }
    }
}
