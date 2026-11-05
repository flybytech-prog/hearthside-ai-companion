import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    // Hearthside's own full-colour icons (Keyboard Shortcuts, About and the
    // window icon come from Plasma and stay as they are).
    ConfigCategory {
        name: i18n("General")
        icon: Qt.resolvedUrl("../images/settings-general.svg")
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: i18n("AI Provider Settings")
        icon: Qt.resolvedUrl("../images/settings-ai.svg")
        source: "configUsage.qml"
    }
    ConfigCategory {
        name: i18n("Chat")
        icon: Qt.resolvedUrl("../images/settings-chat.svg")
        source: "configChat.qml"
    }
}
