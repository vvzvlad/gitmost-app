import AppKit
import WebKit
import DocmostCore

// Wraps one persistent WKWebView bound to a single server. Created lazily on first
// selection and kept alive so switching tabs preserves scroll position and login state.
final class WebTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    // All tabs share one process pool so they cooperate as a single browser session.
    private static let sharedProcessPool = WKProcessPool()

    let server: Server
    let webView: DragImportWebView

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

        self.webView = DragImportWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        webView.onMarkdownFilesDropped = { [weak self] urls in
            self?.importMarkdownFiles(urls)
        }

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

    // Whether to show the in-app Back button: the user is on a page they cannot
    // navigate back from within Docmost's own UI — an external site, or a read-only
    // public "share" page on the same domain.
    var showsBackButton: Bool {
        isShowingExternalContent || server.isSharePageURL(webView.url)
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
        if webView.canGoBack {
            webView.goBack()
        } else if showsBackButton {
            // No history to step back to, but we're on an external or read-only
            // share page — escape to the server home so the user is never stuck.
            // Keep `hasLoaded` honest (a load is being issued) so reload() stays correct.
            hasLoaded = true
            webView.load(URLRequest(url: server.url))
        }
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

    // MARK: - Markdown drag-and-drop import

    // Imports Markdown files dropped on the web view as Docmost pages, into the space
    // currently open in this tab. Runs as JavaScript in the page via callAsyncJavaScript,
    // so it authenticates with the page's own session cookie and needs no cookie handling.
    private func importMarkdownFiles(_ urls: [URL]) {
        // The import endpoint needs a target space; derive it from the live URL.
        guard let path = webView.url?.path,
              let slug = MarkdownImport.spaceSlug(fromPath: path) else {
            presentImportAlert(title: "Can't import here",
                               text: "Open a space, then drop Markdown files to import them as pages.")
            return
        }

        // Read each file into a base64 payload for the web view; collect read errors.
        var files: [[String: String]] = []
        var errors: [String] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                if data.count > MarkdownImport.maxFileSize {
                    errors.append("\(url.lastPathComponent): file is too large")
                    continue
                }
                files.append(["name": url.lastPathComponent, "b64": data.base64EncodedString()])
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !files.isEmpty else {
            presentImportAlert(title: "Import failed", text: errors.joined(separator: "\n"))
            return
        }

        let arguments: [String: Any] = ["slug": slug, "files": files]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await self.webView.callAsyncJavaScript(MarkdownImport.importMarkdownJS,
                                                                       arguments: arguments,
                                                                       in: nil,
                                                                       contentWorld: .page)
                self.handleImportResult(value, readErrors: errors)
            } catch {
                self.presentImportAlert(title: "Import failed", text: error.localizedDescription)
            }
        }
    }

    // Reloads the tab when anything imported (so the page tree shows the new pages) and
    // surfaces any per-file failures.
    private func handleImportResult(_ value: Any?, readErrors: [String]) {
        var imported = 0
        var errors = readErrors
        if let dict = value as? [String: Any] {
            imported = (dict["imported"] as? NSNumber)?.intValue ?? 0
            if let jsErrors = dict["errors"] as? [String] { errors.append(contentsOf: jsErrors) }
        }

        if imported > 0 { reload() }

        if !errors.isEmpty {
            let noun = imported == 1 ? "page" : "pages"
            let title = imported > 0 ? "Import finished with errors" : "Import failed"
            let prefix = imported > 0 ? "Imported \(imported) \(noun), but some files failed:\n" : ""
            presentImportAlert(title: title, text: prefix + errors.joined(separator: "\n"))
        }
    }

    // Shows a native alert, as a sheet on the web view's window when available.
    private func presentImportAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
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
