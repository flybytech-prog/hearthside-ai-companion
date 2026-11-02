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
    property int appletId: 0
    property var offSite: ({off: false, host: ""})
    property string activeSiteName: ""
    property string localOwnerProblem: ""
    property int localOwnerPort: 0
    property bool localOwnerChecking: false
    property string externalUrl: ""
    property string externalHost: ""
    property int retries: 0
    property int homes: 0
    property int dismissals: 0
    property int opened: 0
    property int cancelled: 0

    function goBack() {}
    function reload() {}
    function home() { homes++ }
    function retryLocalOwner() { retries++ }
    function dismissLocalOwner() { dismissals++; localOwnerProblem = "" }
    function acceptExternal() { opened++; externalUrl = ""; externalHost = "" }
    function clearExternal() { cancelled++; externalUrl = ""; externalHost = "" }
    function openExternally() {}
    function focusView() {}
    function cancelDownload() {}
    function closeOverlay() {}
    function saveDownload() {}
}
