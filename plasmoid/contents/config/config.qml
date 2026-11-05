import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    // Hearthside's own icons, installed to the icon theme by install.sh so
    // Plasma recolours them like its own (Keyboard Shortcuts, About and the
    // window icon come from Plasma and stay as they are).
    ConfigCategory {
        name: i18n("General")
        icon: "hearthside-settings-general"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: i18n("AI Provider Settings")
        icon: "hearthside-settings-ai"
        source: "configUsage.qml"
    }
    ConfigCategory {
        name: i18n("Chat")
        icon: "hearthside-settings-chat"
        source: "configChat.qml"
    }
}
