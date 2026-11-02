import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import QtWebEngine
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "ChatSites.js" as ChatSites

// The only file that touches Qt WebEngine. Everything lives in one profile.
// By default it is off the record: cookies, cache and site storage stay in
// memory and vanish when this item is destroyed (Clear chat data) or Plasma
// restarts. Only with "Stay signed in" and a verified, unlocked encrypted
// folder does ChatView create this item with staySignedIn set; then cookies
// and site storage live in storagePath inside that folder (HTTP cache stays in
// memory). Both are fixed for the item's lifetime: ChatView recreates it
// instead of changing them (a live switch crashes Qt WebEngine).
// Pages are never read or scripted, and their console output is dropped.
//
// Local web UI pages on this computer load only after the helper said the
// port belongs to this user or the system (LocalOwnerCheck): before the
// Local view is created and before each of its main-frame navigations to
// this computer. Anything else loads nothing and shows a message instead.
Item {
    id: chatWeb

    // Set once through the Loader's initial properties, before the profile
    // exists. Defaults are the private in-memory profile.
    property bool staySignedIn: false
    property string storagePath: ""
    property string profileName: ""

    // Enabled site ids (catalog order) and the one being shown.
    property var siteIds: []
    property string siteId: ""
    // Validated {siteId: url} custom addresses; set before siteId so the
    // first load already uses them.
    property var customUrls: ({})
    // Only makes the owner check's helper source name unique.
    property int appletId: 0

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
        && ChatSites.isPageUrl(
            ChatSites.effectiveSite(chatWeb.activeView.site, chatWeb.customUrls),
            chatWeb.activeView.url.toString())

    // Off-site notice for the page shown: {off, host} from ChatSites.
    readonly property var offSite: chatWeb.activeView
        ? ChatSites.offSiteHost({
            siteId: chatWeb.activeView.site,
            customUrls: chatWeb.customUrls,
            url: chatWeb.activeView.url.toString()
        })
        : ({off: false, host: ""})
    readonly property string activeSiteName: {
        var site = chatWeb.activeView ? ChatSites.byId(chatWeb.activeView.site) : null
        return site ? site.name : ""
    }

    // Local web UI owner check. Problem codes as OllamaChat.ownerProblem,
    // plus "resend" after a checked form post; port is the one checked.
    property string localOwnerProblem: ""
    property int localOwnerPort: 0
    readonly property bool localOwnerChecking: localOwner.busy
    // What waits for the check: {view, url, form, create}, or null.
    property var ownerPending: null
    // The address a good check before creating the Local view was made
    // for; handed to that view as its first pass.
    property string localCreatePass: ""

    property bool dialogOpen: false
    property bool passkeyNotice: false
    property var overlayView: null
    property var pendingDownload: null
    property string pendingDownloadName: ""

    // The profile's own user agent (QtWebEngine token stripped) and client
    // hints, captured once; restored whenever no page is on Google sign-in.
    property string baseUserAgent: ""
    property bool baseClientHintsEnabled: true
    property var baseBrands: ({})

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
        var url = ChatSites.homeUrl(chatWeb.siteId, chatWeb.customUrls)
        if (chatWeb.currentView && url !== "")
            chatWeb.currentView.url = url
    }

    function openExternally() {
        if (chatWeb.canOpenExternally)
            Qt.openUrlExternally(chatWeb.activeView.url)
    }

    function focusView() {
        if (chatWeb.activeView)
            chatWeb.activeView.forceActiveFocus()
    }

    // A Local main-frame navigation (or creating the Local view, view null)
    // waits for the owner check; the request itself was already rejected.
    function checkLocalOwner(view, url, form, create) {
        var port = ChatSites.localOwnerPort({ siteId: "local", customUrls: chatWeb.customUrls, url: url })
        // A late answer of an earlier check must not count for this one.
        localOwner.cancel()
        chatWeb.ownerPending = { view: view, url: url, port: port, form: form, create: create }
        chatWeb.localOwnerPort = port
        // Never from inside the navigation request itself.
        Qt.callLater(function () {
            if (chatWeb.ownerPending && chatWeb.ownerPending.url === url)
                localOwner.start(port)
        })
    }

    function localOwnerFinished(port, problem) {
        var pending = chatWeb.ownerPending
        if (!pending || pending.port !== port)
            return
        chatWeb.ownerPending = null
        if (problem !== "") {
            // Fail closed: nothing from this computer stays on screen, so a
            // page loaded earlier can't keep talking to the new listener.
            chatWeb.localOwnerProblem = problem
            chatWeb.blankLocalViews()
            return
        }
        chatWeb.localOwnerProblem = ""
        if (pending.create) {
            if (chatWeb.siteIds.indexOf("local") < 0 || chatWeb.viewFor("local") !== null)
                return
            chatWeb.localCreatePass = pending.url
            visitedSites.append({ site: "local" })
            return
        }
        var view = pending.view
        if (!view || chatWeb.viewList().indexOf(view) < 0)
            return
        view.ownerPass = pending.url
        // A form post can't be replayed; the user sends it again.
        if (pending.form) {
            chatWeb.localOwnerProblem = "resend"
            return
        }
        view.url = pending.url
    }

    function blankLocalViews() {
        var views = chatWeb.viewList()
        for (var index = 0; index < views.length; index++) {
            var view = views[index]
            view.ownerPass = ""
            if (ChatSites.localOwnerPort({ siteId: view.site, customUrls: chatWeb.customUrls,
                                           url: view.url.toString() }) > 0)
                view.url = "about:blank"
        }
    }

    // Retry after a problem: create the Local view again, or go home.
    function retryLocalOwner() {
        chatWeb.localOwnerProblem = ""
        if (chatWeb.viewFor("local") === null)
            chatWeb.syncViews()
        else if (chatWeb.siteId === "local")
            chatWeb.home()
    }

    function closeOverlay() {
        if (!chatWeb.overlayView)
            return
        var view = chatWeb.overlayView
        chatWeb.overlayView = null
        view.destroy()
        Qt.callLater(chatWeb.syncUserAgent)
    }

    // Addresses of every page and the sign-in window; view's own address is
    // replaced by pendingUrl (the one it is about to load).
    function viewList() {
        var views = []
        for (var index = 0; index < pages.count; index++) {
            if (pages.itemAt(index))
                views.push(pages.itemAt(index))
        }
        if (chatWeb.overlayView)
            views.push(chatWeb.overlayView)
        return views
    }

    function viewUrls(view, pendingUrl) {
        var views = chatWeb.viewList()
        var urls = []
        for (var index = 0; index < views.length; index++) {
            if (views[index] !== view)
                urls.push(views[index].url.toString())
        }
        if (view)
            urls.push(pendingUrl)
        return urls
    }

    function wantedUserAgent(view, pendingUrl) {
        return ChatSites.userAgentFor(chatWeb.viewUrls(view, pendingUrl), chatWeb.baseUserAgent)
    }

    // The user agent is profile-wide and only a plain property, but it must
    // never be set from inside a navigation request (that aborts Qt
    // WebEngine); callers defer this. On Google sign-in, client hints are
    // emptied too so they don't name Chromium behind the Firefox agent.
    function applyUserAgent(userAgent) {
        if (chatWeb.baseUserAgent === "" || chatProfile.httpUserAgent === userAgent)
            return
        var firefox = userAgent === ChatSites.GOOGLE_SIGNIN_UA
        chatProfile.clientHints.isAllClientHintsEnabled = firefox ? false : chatWeb.baseClientHintsEnabled
        chatProfile.clientHints.fullVersionList = firefox ? ({}) : chatWeb.baseBrands
        chatProfile.httpUserAgent = userAgent
    }

    // Settles the user agent from the loaded addresses, but only while no
    // page is loading: a load in flight is handled by its own request and
    // ends with another sync.
    function syncUserAgent() {
        var views = chatWeb.viewList()
        for (var index = 0; index < views.length; index++) {
            if (views[index].loading)
                return
        }
        chatWeb.applyUserAgent(chatWeb.wantedUserAgent(null, ""))
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
        if (chatWeb.ownerPending && chatWeb.ownerPending.create
                && chatWeb.siteIds.indexOf("local") < 0) {
            localOwner.cancel()
            chatWeb.ownerPending = null
        }
        // Append only: existing views keep their page and are never reloaded.
        // A Local view on this computer is created only after the owner check.
        if (chatWeb.siteIds.indexOf(chatWeb.siteId) >= 0
                && chatWeb.viewFor(chatWeb.siteId) === null) {
            var home = ChatSites.homeUrl(chatWeb.siteId, chatWeb.customUrls)
            if (ChatSites.localOwnerPort({ siteId: chatWeb.siteId, customUrls: chatWeb.customUrls,
                                           url: home }) === 0)
                visitedSites.append({ site: chatWeb.siteId })
            else if (!(chatWeb.ownerPending && chatWeb.ownerPending.create))
                chatWeb.checkLocalOwner(null, home, false, true)
        }
        chatWeb.currentView = chatWeb.viewFor(chatWeb.siteId)
    }

    // A changed address moves only the views whose home actually changed.
    function applyCustomUrls() {
        for (var index = 0; index < pages.count; index++) {
            var view = pages.itemAt(index)
            if (!view || view.isOverlay)
                continue
            var url = ChatSites.homeUrl(view.site, chatWeb.customUrls)
            if (url === "" || url === view.homeUrl)
                continue
            if (chatWeb.overlayView && chatWeb.overlayView.site === view.site)
                chatWeb.closeOverlay()
            view.homeUrl = url
            view.failed = false
            view.crashed = false
            view.url = url
        }
    }

    onSiteIdsChanged: chatWeb.syncViews()
    onCustomUrlsChanged: chatWeb.applyCustomUrls()
    onSiteIdChanged: {
        chatWeb.closeOverlay()
        chatWeb.passkeyNotice = false
        chatWeb.syncViews()
    }

    Component.onCompleted: {
        chatWeb.baseUserAgent = ChatSites.userAgent(chatProfile.httpUserAgent)
        chatWeb.baseClientHintsEnabled = chatProfile.clientHints.isAllClientHintsEnabled
        chatWeb.baseBrands = chatProfile.clientHints.fullVersionList
        chatProfile.httpUserAgent = chatWeb.baseUserAgent
        chatWeb.syncViews()
    }

    Component.onDestruction: {
        localOwner.cancel()
        chatWeb.cancelDownload()
        if (uploadDialog.request)
            chatWeb.finishUpload(false)
    }

    // Order matters: the paths come before storageName and offTheRecord is
    // last, or Qt creates a stray profile folder under Plasma's own data
    // directory before it sees the paths.
    WebEngineProfile {
        id: chatProfile
        persistentStoragePath: chatWeb.staySignedIn ? chatWeb.storagePath : ""
        cachePath: chatWeb.staySignedIn ? chatWeb.storagePath : ""
        storageName: chatWeb.staySignedIn ? chatWeb.profileName : ""
        httpCacheType: WebEngineProfile.MemoryHttpCache
        persistentCookiesPolicy: chatWeb.staySignedIn
            ? WebEngineProfile.AllowPersistentCookies : WebEngineProfile.NoPersistentCookies
        persistentPermissionsPolicy: WebEngineProfile.PersistentPermissionsPolicy.AskEveryTime
        spellCheckEnabled: false
        offTheRecord: !chatWeb.staySignedIn

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

    LocalOwnerCheck {
        id: localOwner
        objectName: "localOwnerCheck"
        appletId: chatWeb.appletId
        onFinished: (port, problem) => chatWeb.localOwnerFinished(port, problem)
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
            // The address this view was opened with (custom or built-in).
            property string homeUrl: ""
            property bool failed: false
            property bool crashed: false
            // Address re-requested once after a user agent switch.
            property string userAgentRetry: ""
            // Address a good owner check was just made for (Local only);
            // used up by the next main-frame navigation.
            property string ownerPass: ""

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
                    siteId: page.site,
                    customUrls: chatWeb.customUrls
                })
                if (verdict === "allow") {
                    if (!request.isMainFrame)
                        return
                    var url = request.url.toString()
                    var gate = ChatSites.localOwnerGate({
                        url: url,
                        isMainFrame: request.isMainFrame,
                        siteId: page.site,
                        customUrls: chatWeb.customUrls,
                        pass: page.ownerPass
                    })
                    if (gate !== "skip")
                        page.ownerPass = ""
                    if (gate === "check") {
                        request.reject()
                        chatWeb.checkLocalOwner(page, url, request.navigationType
                            === WebEngineNavigationRequest.FormSubmittedNavigation, false)
                        return
                    }
                    page.checkUserAgent(request)
                    return
                }
                request.reject()
                if (verdict === "external")
                    Qt.openUrlExternally(request.url)
            }

            onNewWindowRequested: (request) => {
                var url = request.requestedUrl.toString()
                var verdict = ChatSites.classifyNewWindow({
                    url: url,
                    isDialog: request.destination === WebEngineNewWindowRequest.InNewDialog,
                    siteId: page.site,
                    customUrls: chatWeb.customUrls
                })
                // A Local window starting on this computer would skip the
                // owner check: dropped.
                if (verdict === "overlay" && ChatSites.localOwnerPort({
                        siteId: page.site, customUrls: chatWeb.customUrls, url: url }) > 0)
                    return
                // A sign-in window cannot open another overlay on top of itself.
                if (verdict === "overlay" && !page.isOverlay)
                    chatWeb.openOverlay(request, page.site)
                // Only a click may hand an address to the system browser
                // (external or nested sign-in); script-opened ones are dropped.
                else if (verdict !== "block" && request.userInitiated
                         && ChatSites.isHttpsUrl(url))
                    Qt.openUrlExternally(url)
            }

            // A main-frame load that needs the other user agent is stopped
            // and asked again once the switch is done, so its very first
            // request already carries the right one. A form post can't be
            // replayed: it goes out as is and the switch follows at the end
            // of the load.
            function checkUserAgent(request) {
                var url = request.url.toString()
                var retried = page.userAgentRetry === url
                page.userAgentRetry = ""
                if (retried || chatWeb.wantedUserAgent(page, url) === chatProfile.httpUserAgent)
                    return
                if (request.navigationType === WebEngineNavigationRequest.FormSubmittedNavigation)
                    return
                request.reject()
                page.userAgentRetry = url
                Qt.callLater(function () {
                    // Closed meanwhile (sign-in window, disabled site).
                    if (chatWeb.viewList().indexOf(page) < 0)
                        return
                    chatWeb.applyUserAgent(chatWeb.wantedUserAgent(page, url))
                    page.url = url
                })
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
                if (loadingInfo.status !== WebEngineLoadingInfo.LoadStartedStatus)
                    Qt.callLater(chatWeb.syncUserAgent)
            }

            onRenderProcessTerminated: (terminationStatus, exitCode) => {
                if (terminationStatus !== WebEngineView.NormalTerminationStatus)
                    page.crashed = true
            }

            Component.onCompleted: {
                if (page.isOverlay)
                    return
                if (page.site === "local") {
                    page.ownerPass = chatWeb.localCreatePass
                    chatWeb.localCreatePass = ""
                }
                page.homeUrl = ChatSites.homeUrl(page.site, chatWeb.customUrls)
                if (page.homeUrl !== "")
                    page.url = page.homeUrl
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
