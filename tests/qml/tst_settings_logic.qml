import QtQuick
import QtTest
import "../../plasmoid/contents/ui/SettingsLogic.js" as SettingsLogic

TestCase {
    name: "SettingsLogic"

    function test_defaultTab() {
        compare(SettingsLogic.normalizeDefaultTab("chat"), "chat")
        compare(SettingsLogic.normalizeDefaultTab("usage"), "usage")
        compare(SettingsLogic.normalizeDefaultTab(""), "chat")
        compare(SettingsLogic.normalizeDefaultTab("Usage"), "chat")
        compare(SettingsLogic.normalizeDefaultTab(undefined), "chat")
        compare(SettingsLogic.normalizeDefaultTab(1), "chat")
    }

    function test_popupSize() {
        compare(SettingsLogic.normalizePopupSize("compact"), "compact")
        compare(SettingsLogic.normalizePopupSize("normal"), "normal")
        compare(SettingsLogic.normalizePopupSize("large"), "large")
        compare(SettingsLogic.normalizePopupSize("huge"), "normal")
        compare(SettingsLogic.normalizePopupSize(""), "normal")
        compare(SettingsLogic.normalizePopupSize(undefined), "normal")
        compare(SettingsLogic.popupScale("compact"), 0.8)
        compare(SettingsLogic.popupScale("normal"), 1)
        compare(SettingsLogic.popupScale("large"), 1.25)
        compare(SettingsLogic.popupScale("constructor"), 1)
        compare(SettingsLogic.popupScale(null), 1)
    }

    function test_visibleTabs() {
        compare(SettingsLogic.visibleTabs(true, true, true), {usage: true, chat: true})
        compare(SettingsLogic.visibleTabs(true, false, true), {usage: true, chat: false})
        compare(SettingsLogic.visibleTabs(false, true, true), {usage: false, chat: true})
        // Chat needs an enabled site; the popup is never empty.
        compare(SettingsLogic.visibleTabs(false, true, false), {usage: true, chat: false})
        compare(SettingsLogic.visibleTabs(true, true, false), {usage: true, chat: false})
        // Both off (only by hand-editing the config): Usage, never Chat.
        compare(SettingsLogic.visibleTabs(false, false, true), {usage: true, chat: false})
        // Chat only when the setting is exactly true.
        compare(SettingsLogic.visibleTabs(true, "true", true), {usage: true, chat: false})
        compare(SettingsLogic.visibleTabs(true, undefined, true), {usage: true, chat: false})
        compare(SettingsLogic.visibleTabs(undefined, true, true), {usage: true, chat: true})
    }

    function test_shownTab() {
        var both = {usage: true, chat: true}
        var usageOnly = {usage: true, chat: false}
        var chatOnly = {usage: false, chat: true}
        compare(SettingsLogic.shownTab("chat", both), "chat")
        compare(SettingsLogic.shownTab("usage", both), "usage")
        compare(SettingsLogic.shownTab("odd", both), "chat")
        compare(SettingsLogic.shownTab("chat", usageOnly), "usage")
        compare(SettingsLogic.shownTab("usage", usageOnly), "usage")
        compare(SettingsLogic.shownTab("usage", chatOnly), "chat")
        compare(SettingsLogic.shownTab("chat", chatOnly), "chat")
        compare(SettingsLogic.shownTab("chat", undefined), "usage")
    }

    function test_canUntick() {
        verify(SettingsLogic.canUntick(true))
        verify(!SettingsLogic.canUntick(false))
        verify(!SettingsLogic.canUntick(undefined))
    }
}
