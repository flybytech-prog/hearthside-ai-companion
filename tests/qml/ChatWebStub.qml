import QtQuick

// Stands in for ChatWebView.qml in tst_chat_view.qml: same properties ChatView
// reads, no Qt WebEngine.
Item {
    property bool staySignedIn: false
    property string storagePath: ""
    property string profileName: ""
    property var siteIds: []
    property string siteId: ""
    property var customUrls: ({})
    property bool dialogOpen: false
    property bool canGoBack: false
    property bool canOpenExternally: false
    property bool loading: false
    property real loadProgress: 0
    property string pendingDownloadName: ""
    property bool passkeyNotice: false
    property bool pageCrashed: false
    property bool pageFailed: false

    function goBack() {}
    function reload() {}
    function home() {}
    function openExternally() {}
    function focusView() {}
    function cancelDownload() {}
    function closeOverlay() {}
    function saveDownload() {}
}
