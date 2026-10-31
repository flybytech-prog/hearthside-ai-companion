import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import QtWebEngine
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "ChatSites.js" as ChatSites

// The only file that touches Qt WebEngine. Everything lives in one
// off-the-record profile: cookies, cache and site storage stay in memory and
// vanish when this item is destroyed (Clear chat data) or Plasma restarts.
// Pages are never read or scripted, and their console output is dropped.
Item {
    id: chatWeb

    // Enabled site ids (catalog order) and the one being shown.
    property var siteIds: []
    property string siteId: ""

    readonly property bool offTheRecord: chatProfile.offTheRecord
    property var currentView: null
    readonly property bool overlayOpen: chatWeb.overlayView !== null
    readonly property var activeView: chatWeb.overlayView || chatWeb.currentView
    readonly property bool canGoBack: !!chatWeb.activeView && chatWeb.activeView.canGoBack
    readonly property bool loading: !!chatWeb.activeView && chatWeb.activeView.loading
    readonly property real loadProgress: chatWeb.activeView
        ? chatWeb.activeView.loadProgress / 100 : 0
    readonly property bool pageFailed: !!chatWeb.activeView && chatWeb.activeView.failed
    readonly property bool pageCrashed: !!chatWeb.activeView && chatWeb.activeView.crashed
    readonly property bool canOpenExternally: !!chatWeb.activeView
        && ChatSites.isHttpsUrl(chatWeb.activeView.url)

    property bool dialogOpen: false
    property bool passkeyNotice: false
    property var overlayView: null
    property var pendingDownload: null
    property string pendingDownloadName: ""

    function goBack() {
        if (chatWeb.activeView)
            chatWeb.activeView.goBack()
    }

    function reload() {
        if (!chatWeb.activeView)
            return
        chatWeb.activeView.failed = false
        chatWeb.activeView.crashed = false
        chatWeb.activeView.reload()
    }

    function home() {
        chatWeb.closeOverlay()
        var site = ChatSites.byId(chatWeb.siteId)
        if (chatWeb.currentView && site)
            chatWeb.currentView.url = site.url
    }

    function openExternally() {
        if (chatWeb.canOpenExternally)
            Qt.openUrlExternally(chatWeb.activeView.url)
    }

    function focusView() {
        if (chatWeb.activeView)
            chatWeb.activeView.forceActiveFocus()
    }

    function closeOverlay() {
        if (!chatWeb.overlayView)
            return
        var view = chatWeb.overlayView
        chatWeb.overlayView = null
        view.destroy()
    }

    function openOverlay(request, siteId) {
        chatWeb.closeOverlay()
        var view = pageComponent.createObject(overlayContent, {
            site: siteId,
            isOverlay: true
        })
        if (!view)
            return
        chatWeb.overlayView = view
        request.openIn(view)
        Qt.callLater(chatWeb.focusView)
    }

    function saveDownload() {
        var download = chatWeb.pendingDownload
        chatWeb.clearPendingDownload()
        if (download)
            download.accept()
    }

    function cancelDownload() {
        var download = chatWeb.pendingDownload
        chatWeb.clearPendingDownload()
        try {
            if (download)
                download.cancel()
        } catch (error) {
            // Already gone together with the profile.
        }
    }

    function clearPendingDownload() {
        downloadTimeout.stop()
        chatWeb.pendingDownload = null
        chatWeb.pendingDownloadName = ""
    }

    function openUploadDialog(request) {
        if (chatWeb.dialogOpen
                || (request.mode !== FileDialogRequest.FileModeOpen
                    && request.mode !== FileDialogRequest.FileModeOpenMultiple)) {
            // Folder uploads and save pickers are refused; reading is file-by-file.
            request.accepted = true
            request.dialogReject()
            return
        }
        request.accepted = true
        uploadDialog.request = request
        uploadDialog.fileMode = request.mode === FileDialogRequest.FileModeOpenMultiple
            ? FileDialog.OpenFiles : FileDialog.OpenFile
        chatWeb.dialogOpen = true
        uploadDialog.open()
    }

    function finishUpload(accepted) {
        var request = uploadDialog.request
        uploadDialog.request = null
        chatWeb.dialogOpen = false
        if (!request)
            return
        var paths = []
        if (accepted) {
            var files = uploadDialog.selectedFiles
            for (var index = 0; index < files.length; index++) {
                var text = String(files[index])
                if (text.indexOf("file:///") !== 0)
                    continue
                try {
                    paths.push(decodeURIComponent(text.slice(7)))
                } catch (error) {
                    // Undecodable name: skip it rather than log the path.
                }
            }
        }
        if (paths.length > 0)
            request.dialogAccept(paths)
        else
            request.dialogReject()
    }

    function viewFor(siteId) {
        for (var index = 0; index < pages.count; index++) {
            var view = pages.itemAt(index)
            if (view && view.site === siteId)
                return view
        }
        return null
    }

    function syncViews() {
        // Destroy views of sites that were disabled in the settings.
        for (var index = visitedSites.count - 1; index >= 0; index--) {
            if (chatWeb.siteIds.indexOf(visitedSites.get(index).site) < 0)
                visitedSites.remove(index)
        }
        if (chatWeb.overlayView && chatWeb.siteIds.indexOf(chatWeb.overlayView.site) < 0)
            chatWeb.closeOverlay()
        // Append only: existing views keep their page and are never reloaded.
        if (chatWeb.siteIds.indexOf(chatWeb.siteId) >= 0
                && chatWeb.viewFor(chatWeb.siteId) === null)
            visitedSites.append({ site: chatWeb.siteId })
        chatWeb.currentView = chatWeb.viewFor(chatWeb.siteId)
    }

    onSiteIdsChanged: chatWeb.syncViews()
    onSiteIdChanged: {
        chatWeb.closeOverlay()
        chatWeb.passkeyNotice = false
        chatWeb.syncViews()
    }

    Component.onCompleted: {
        chatProfile.httpUserAgent = ChatSites.userAgent(chatProfile.httpUserAgent)
        chatWeb.syncViews()
    }

    Component.onDestruction: {
        chatWeb.cancelDownload()
        if (uploadDialog.request)
            chatWeb.finishUpload(false)
    }

    WebEngineProfile {
        id: chatProfile
        offTheRecord: true
        httpCacheType: WebEngineProfile.MemoryHttpCache
        persistentCookiesPolicy: WebEngineProfile.NoPersistentCookies
        persistentPermissionsPolicy: WebEngineProfile.PersistentPermissionsPolicy.AskEveryTime
        spellCheckEnabled: false

        onDownloadRequested: (download) => {
            if (download.isSavePageDownload || chatWeb.pendingDownload !== null) {
                download.cancel()
                return
            }
            // Deferred: the request stays pending until Save, Cancel or timeout.
            chatWeb.pendingDownload = download
            chatWeb.pendingDownloadName = download.downloadFileName
            downloadTimeout.restart()
        }
    }

    Timer {
        id: downloadTimeout
        interval: 60000
        onTriggered: chatWeb.cancelDownload()
    }

    ListModel {
        id: visitedSites
    }

    Component {
        id: pageComponent

        WebEngineView {
            id: page

            required property string site
            property bool isOverlay: false
            property bool failed: false
            property bool crashed: false

            anchors.fill: parent
            visible: page.isOverlay || page.site === chatWeb.siteId
            profile: chatProfile
            backgroundColor: Kirigami.Theme.backgroundColor

            settings.screenCaptureEnabled: false
            settings.pluginsEnabled: false
            settings.dnsPrefetchEnabled: false
            settings.navigateOnDropEnabled: false
            settings.localContentCanAccessFileUrls: false
            settings.allowRunningInsecureContent: false
            settings.javascriptCanAccessClipboard: false
            settings.javascriptCanPaste: false
            settings.focusOnNavigationEnabled: false
            settings.unknownUrlSchemePolicy: WebEngineSettings.DisallowUnknownUrlSchemes

            // Page console output must never reach the journal.
            onJavaScriptConsoleMessage: (level, message, lineNumber, sourceID) => {}

            onPermissionRequested: (permission) => {
                permission.deny()
            }
            onFullScreenRequested: (request) => {
                request.reject()
            }
            onCertificateError: (error) => {
                error.rejectCertificate()
            }
            onAuthenticationDialogRequested: (request) => {
                request.accepted = true
                request.dialogReject()
            }
            onSelectClientCertificate: (selection) => {
                selection.selectNone()
            }
            onFileSystemAccessRequested: (request) => {
                request.reject()
            }
            onDesktopMediaRequested: (request) => {
                request.cancel()
            }
            onRegisterProtocolHandlerRequested: (request) => {
                request.reject()
            }
            onWebAuthUxRequested: (request) => {
                request.cancel()
                chatWeb.passkeyNotice = true
            }
            onFileDialogRequested: (request) => {
                chatWeb.openUploadDialog(request)
            }

            onNavigationRequested: (request) => {
                var verdict = ChatSites.classifyNavigation({
                    url: request.url.toString(),
                    isMainFrame: request.isMainFrame,
                    linkClicked: request.navigationType
                        === WebEngineNavigationRequest.LinkClickedNavigation,
                    siteId: page.site
                })
                if (verdict === "allow")
                    return
                request.reject()
                if (verdict === "external")
                    Qt.openUrlExternally(request.url)
            }

            onNewWindowRequested: (request) => {
                var url = request.requestedUrl.toString()
                var verdict = ChatSites.classifyNewWindow({
                    url: url,
                    isDialog: request.destination === WebEngineNewWindowRequest.InNewDialog,
                    siteId: page.site
                })
                // A sign-in window cannot open another overlay on top of itself.
                if (verdict === "overlay" && !page.isOverlay)
                    chatWeb.openOverlay(request, page.site)
                // Only a click may hand an address to the system browser
                // (external or nested sign-in); script-opened ones are dropped.
                else if (verdict !== "block" && request.userInitiated
                         && ChatSites.isHttpsUrl(url))
                    Qt.openUrlExternally(url)
            }

            onWindowCloseRequested: {
                if (page.isOverlay)
                    chatWeb.closeOverlay()
            }

            onLoadingChanged: (loadingInfo) => {
                if (loadingInfo.status === WebEngineLoadingInfo.LoadStartedStatus)
                    page.failed = false
                // Aborted loads (-3) come from our own rejections; not a failure.
                else if (loadingInfo.status === WebEngineLoadingInfo.LoadFailedStatus
                        && loadingInfo.errorCode !== -3)
                    page.failed = true
            }

            onRenderProcessTerminated: (terminationStatus, exitCode) => {
                if (terminationStatus !== WebEngineView.NormalTerminationStatus)
                    page.crashed = true
            }

            Component.onCompleted: {
                var descriptor = ChatSites.byId(page.site)
                if (!page.isOverlay && descriptor)
                    page.url = descriptor.url
            }
        }
    }

    Repeater {
        id: pages
        model: visitedSites
        delegate: pageComponent
        onItemAdded: chatWeb.currentView = chatWeb.viewFor(chatWeb.siteId)
        onItemRemoved: chatWeb.currentView = chatWeb.viewFor(chatWeb.siteId)
    }

    Rectangle {
        id: overlay
        anchors.fill: parent
        visible: chatWeb.overlayOpen
        color: Kirigami.Theme.backgroundColor

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "dialog-password"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: i18n("Sign-in window")
                    elide: Text.ElideRight
                }
                PlasmaComponents.ToolButton {
                    text: i18n("Close")
                    icon.name: "window-close"
                    onClicked: chatWeb.closeOverlay()
                }
            }
            Kirigami.Separator {
                Layout.fillWidth: true
            }
            Item {
                id: overlayContent
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }

    FileDialog {
        id: uploadDialog
        property var request: null
        title: i18n("Choose files to upload")
        onAccepted: chatWeb.finishUpload(true)
        onRejected: chatWeb.finishUpload(false)
    }
}
