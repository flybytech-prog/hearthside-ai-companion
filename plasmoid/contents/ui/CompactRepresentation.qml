import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

MouseArea {
    id: compactRoot

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical

    Layout.minimumWidth: vertical ? Kirigami.Units.iconSizes.small : height
    Layout.minimumHeight: vertical ? width : Kirigami.Units.iconSizes.small
    Layout.preferredWidth: vertical ? -1 : height
    Layout.preferredHeight: vertical ? width : -1

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: (mouse) => {
        if (mouse.button === Qt.MiddleButton)
            root.refresh()
        else
            root.expanded = !root.expanded
    }

    // Text dragged from another program onto the icon opens the Ollama chat
    // with the text in its message box; nothing is sent until Send. Only
    // text: drags with files or links are refused.
    DropArea {
        anchors.fill: parent
        enabled: root.ollamaDropTarget
        onEntered: (drag) => {
            if (drag.hasText && !drag.hasUrls)
                drag.accept(Qt.CopyAction)
            else
                drag.accepted = false
        }
        onDropped: (drop) => {
            if (drop.hasText && !drop.hasUrls) {
                root.dropToOllama(drop.text)
                drop.accept(Qt.CopyAction)
            } else {
                drop.accepted = false
            }
        }
    }

    // Only the Hearthside icon is shown in the panel; usage lives in the
    // popup and the tooltip.
    Kirigami.Icon {
        id: content
        anchors.fill: parent
        anchors.margins: Math.round(Kirigami.Units.smallSpacing / 2)
        source: Qt.resolvedUrl("../images/hearthside.svg")
        isMask: true
        color: Kirigami.Theme.textColor
        active: compactRoot.containsMouse
        implicitWidth: Kirigami.Units.iconSizes.smallMedium
        implicitHeight: Kirigami.Units.iconSizes.smallMedium
    }
}
