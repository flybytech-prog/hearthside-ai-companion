import QtQuick
import QtTest
import "../../plasmoid/contents/ui"

// Runtime check of the real ChatWebView: a chat site with a self-signed
// certificate never loads. Run only by tests/webengine/run.sh, inside a
// private network namespace, without any flag that relaxes certificates.
TestCase {
    id: testCase
    name: "UntrustedCertificate"
    width: 800
    height: 600
    visible: true
    when: windowShown

    function i18n(text) {
        var result = text
        for (var index = 1; index < arguments.length; index++)
            result = result.replace("%" + index, String(arguments[index]))
        return result
    }

    Component {
        id: webComponent
        ChatWebView {
            anchors.fill: parent
        }
    }

    property var hits: null

    function fetchHits() {
        testCase.hits = null
        var request = new XMLHttpRequest()
        request.onreadystatechange = function () {
            if (request.readyState === XMLHttpRequest.DONE)
                testCase.hits = request.status === 200 ? JSON.parse(request.responseText) : { error: request.status }
        }
        request.open("GET", "http://127.0.0.1:3999/__hits")
        request.send()
        tryVerify(function () { return testCase.hits !== null }, 5000, "the fake servers did not answer")
        verify(testCase.hits.error === undefined, "hits: " + JSON.stringify(testCase.hits))
        return testCase.hits
    }

    function test_selfSignedSiteFailsToLoad() {
        var web = createTemporaryObject(webComponent, testCase, {})
        verify(web !== null)
        web.siteIds = ["claude"]
        web.siteId = "claude"
        verify(web.currentView !== null)
        tryVerify(function () { return web.pageFailed }, 20000, "the self-signed site did not fail")
        // Give an accepted certificate time to show its page anyway.
        wait(2000)
        verify(web.pageFailed)
        verify(String(web.currentView.title).indexOf("HS:") !== 0, web.currentView.title)
        // The request itself never went out.
        compare(JSON.stringify(testCase.fetchHits().site), "[]")
    }
}
