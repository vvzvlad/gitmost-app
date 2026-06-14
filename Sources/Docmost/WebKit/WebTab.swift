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

    // Guards against reloading the start URL on every tab switch.
    private var hasLoaded = false

    // Tracks the chosen destination per download so we can reveal it on completion.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(server: Server) {
        self.server = server

        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebTab.sharedProcessPool
        // Use the default persistent data store so cookies/logins survive restarts.
        // Cookies are isolated per-domain, which is enough for distinct servers.
        // NOTE: if same-domain multi-account is ever needed, switch to
        // WKWebsiteDataStore(forIdentifier:) for true per-server isolation.
        configuration.websiteDataStore = .default()

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: - Loading / navigation

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        webView.load(URLRequest(url: server.url))
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

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    // Stop any in-flight load and detach delegates before this tab is discarded.
    func tearDown() {
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
           let host = url.host,
           host != server.url.host {
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
