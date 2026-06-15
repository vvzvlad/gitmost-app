import AppKit
import WebKit
import DocmostCore

// Wraps one persistent WKWebView bound to a single server. Created lazily on first
// selection and kept alive so switching tabs preserves scroll position and login state.
final class WebTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    // All tabs share one process pool so they cooperate as a single browser session.
    private static let sharedProcessPool = WKProcessPool()

    let server: Server
    let webView: WKWebView

    // The URL to load on first display — the server's last visited page when known,
    // otherwise the server root. Lets a restart reopen where the user left off.
    private let startURL: URL

    // Guards against reloading the start URL on every tab switch.
    private var hasLoaded = false

    // Fired (on the main thread) whenever the web view's URL changes, so the host
    // controller can refresh navigation chrome (e.g. the Back button).
    var onNavigationStateChanged: (() -> Void)?

    // KVO token for `webView.url`.
    private var urlObservation: NSKeyValueObservation?

    // Tracks the chosen destination per download so we can reveal it on completion.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(server: Server, startURL: URL, customJS: String?, customCSS: String?) {
        self.server = server
        self.startURL = startURL

        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebTab.sharedProcessPool
        // Use the default persistent data store so cookies/logins survive restarts.
        // Cookies are isolated per-domain, which is enough for distinct servers.
        // NOTE: if same-domain multi-account is ever needed, switch to
        // WKWebsiteDataStore(forIdentifier:) for true per-server isolation.
        configuration.websiteDataStore = .default()

        let controller = WKUserContentController()
        WebTab.installUserScripts(into: controller, js: customJS, css: customCSS)
        configuration.userContentController = controller

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Notify the UI when the current location changes so it can show a Back
        // button while foreign (non-server) content is displayed. KVO on `url`
        // fires for full navigations, redirects, back/forward and SPA route
        // changes, all on the main thread.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.onNavigationStateChanged?()
        }
    }

    // MARK: - Loading / navigation

    // True while the web view shows content on a different host than the server
    // (an external site reached via a link, redirect, window.open or form post).
    var isShowingExternalContent: Bool {
        server.isExternalURL(webView.url)
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        webView.load(URLRequest(url: startURL))
    }

    func reload() {
        // If nothing has loaded yet, perform the initial load instead of a no-op reload.
        if hasLoaded {
            webView.reload()
        } else {
            loadIfNeeded()
        }
    }

    // Applies the page zoom factor to this tab's web content.
    func setPageZoom(_ factor: CGFloat) {
        webView.pageZoom = factor
    }

    // MARK: - Custom user scripts

    // Installs the custom CSS (as a <style> injector) and JS user scripts.
    // Both run at document end in the main frame only.
    static func installUserScripts(into controller: WKUserContentController,
                                   js: String?, css: String?) {
        if let css = css, !css.isEmpty {
            let source = UserScripts.styleInjectionJS(forCSS: css)
            controller.addUserScript(WKUserScript(source: source,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        if let js = js, !js.isEmpty {
            controller.addUserScript(WKUserScript(source: js,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    // Stop any in-flight load and detach delegates before this tab is discarded.
    func tearDown() {
        // Cut every change-notification path before mutating the web view, so a
        // teardown-induced URL change can never persist a stale location.
        onNavigationStateChanged = nil
        urlObservation?.invalidate()
        urlObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open: load in the same web view instead of a dead window.
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // WKWebView shows no file chooser for <input type="file"> unless this is
    // implemented. Bridge it to a native NSOpenPanel, honoring the page's
    // directory/multiple-selection hints.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        // Present as a sheet on the web view's window when possible.
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only intercept explicit link clicks to a different host; let redirects and
        // form submits through so SSO/OAuth flows to other hosts keep working.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           server.isExternalURL(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // If the content can't be displayed inline, download it instead.
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        let downloads: URL
        if let dir = try? fileManager.url(for: .downloadsDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true) {
            downloads = dir
        } else {
            downloads = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }

        // WebKit requires the destination not to already exist; add a numeric suffix
        // (e.g. "file 1.pdf") to avoid collisions.
        var destination = downloads.appendingPathComponent(suggestedFilename)
        if fileManager.fileExists(atPath: destination.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            var counter = 1
            repeat {
                let candidateName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                destination = downloads.appendingPathComponent(candidateName)
                counter += 1
            } while fileManager.fileExists(atPath: destination.path)
        }

        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Download failed: \(error.localizedDescription)")
    }
}
