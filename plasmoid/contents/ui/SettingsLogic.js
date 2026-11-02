.pragma library

// Settings → General: pure normalizers for the popup options. Anything odd
// in the configuration falls back to the default.

var POPUP_TABS = ["chat", "usage"]
var POPUP_SIZES = ["compact", "normal", "large"]
var POPUP_SCALES = { compact: 0.8, normal: 1, large: 1.25 }

// "usage" or "chat"; anything else is "chat".
function normalizeDefaultTab(value) {
    return value === "usage" ? "usage" : "chat"
}

// compact, normal or large; anything else is normal.
function normalizePopupSize(value) {
    return POPUP_SIZES.indexOf(value) >= 0 ? value : "normal"
}

function popupScale(value) {
    return POPUP_SCALES[normalizePopupSize(value)]
}

// Which tabs the popup shows. Chat needs the setting on (exactly true) and
// at least one enabled site; Usage shows when it is on or when Chat can't
// show, so the popup is never empty.
function visibleTabs(showUsage, showChat, chatAvailable) {
    var chat = showChat === true && chatAvailable === true
    var usage = showUsage !== false || !chat
    return { usage: usage, chat: chat }
}

// The tab to show: the wanted one if it is visible, else the other.
function shownTab(wanted, tabs) {
    var tab = normalizeDefaultTab(wanted)
    var shown = tabs || { usage: true, chat: false }
    if (tab === "chat" && shown.chat === true)
        return "chat"
    if (tab === "usage" && shown.usage === true)
        return "usage"
    return shown.chat === true && shown.usage !== true ? "chat" : "usage"
}

// The other tab's box must stay checked: false when unticking this one
// would leave no tab.
function canUntick(otherChecked) {
    return otherChecked === true
}
