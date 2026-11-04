import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "configure"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: i18n("AI Provider Settings")
        icon: "speedometer"
        source: "configUsage.qml"
    }
    ConfigCategory {
        name: i18n("Chat")
        icon: "dialog-messages"
        source: "configChat.qml"
    }
}
