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

        // Present as Safari so web libraries that special-case "macOS WebView" user
        // agents behave like in a real browser. Docmost's page export uses file-saver,
        // whose isMacOSWebView branch (taken when the UA lacks a "Safari" token) opens a
        // blank popup and falls back to a data: URL — which blanked the tab. A Safari UA
        // routes export through the normal <a download href="blob:…"> path, which both
        // downloads correctly (blob downloads work on macOS 14 / WebKit 17.3+) and keeps
        // the real filename. applicationNameForUserAgent is appended to the default UA.
        configuration.applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"

        self.webView = DragImportWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Allow attaching Safari's Web Inspector (Develop ▸ <app> ▸ Web Inspector)
        // to this web view. WKWebView-only failures — e.g. a streaming
        // /api/ai-chat/stream SSE that the UI surfaces as the opaque "Load failed"
        // — are otherwise undiagnosable here (the browser exposes no detail); the
        // inspector's Console + Network tab show the real NSURLError, bytes
        // received and timing. macOS 13.3+ (the app targets macOS 14). Consider
        // gating this behind a debug build flag before shipping if inspector
        // access should not be exposed in release builds.
        webView.isInspectable = true

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
        // Capture `errors` by value (not by reference) in the Task's capture list: Swift
        // forbids referencing a captured `var` from concurrently-executing code. This is
        // safe because the array is a value type fully built before the Task is created.
        Task { @MainActor [weak self, errors] in
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

    // MARK: - Recording delivery

    // Creates a NEW child page titled `title` under the configured destination
    // (space `spaceId`, optional parent `parentPageId`; nil parent = space root) and
    // inserts the recording into it. The destination is fixed in Settings; there is no
    // runtime picker and the recording never goes into the currently-open page.
    //
    // `completion` reports whether the recording was delivered somewhere durable: true when
    // the page was created OR the Downloads fallback saved a copy; false only when neither
    // worked. It fires EXACTLY ONCE on the main thread on every path, so the controller can
    // advance the recording phase to done/failed.
    func createRecordingPage(spaceId: String, parentPageId: String?, title: String,
                             fileURL: URL, completion: @escaping (Bool) -> Void) {
        // Read + base64-encode off the main thread: recordings can be tens/hundreds of MB
        // and this method is called on the main thread, so doing it inline would freeze the
        // UI. Hop back to the main thread for the WebKit bridge probe / fallback.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let base64: String
            do {
                base64 = try Data(contentsOf: fileURL).base64EncodedString()
            } catch {
                DispatchQueue.main.async {
                    // If the WebTab was deallocated mid-read (e.g. its server was removed
                    // or its URL changed, dropping the tab), still report completion so the
                    // RecordingController does not hang forever in .saving.
                    guard let self else { completion(false); return }
                    self.recordingFallback(
                        fileURL: fileURL,
                        reason: "Could not read the recording: \(error.localizedDescription)",
                        completion: completion)
                }
                return
            }

            DispatchQueue.main.async {
                // Same guard as above: a deallocated tab must not swallow the completion.
                guard let self else { completion(false); return }
                self.deliverToNewPage(spaceId: spaceId, parentPageId: parentPageId,
                                      title: title, base64: base64,
                                      fileURL: fileURL, completion: completion)
            }
        }
    }

    // Runs on the main thread. Probes the page-creation bridge and creates a new page from
    // the recording, falling back to Downloads when the bridge is missing or reports a
    // failure. `completion` is forwarded down every terminal path so it fires exactly once.
    @MainActor
    private func deliverToNewPage(spaceId: String, parentPageId: String?, title: String,
                                  base64: String, fileURL: URL,
                                  completion: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(false); return }

            // 1. Probe the page-creation bridge; if it is missing, save to Downloads.
            guard await self.bridgeSupportsPageCreation() else {
                self.recordingFallback(fileURL: fileURL,
                                       reason: "This server does not support recording pages yet.",
                                       completion: completion)
                return
            }

            // 2. Create the page; .success deletes the temp file, .failure saves to Downloads.
            let outcome = await self.createPageWithRecording(
                spaceId: spaceId, parentPageId: parentPageId,
                title: title, base64: base64, filename: fileURL.lastPathComponent)
            switch outcome {
            case .success:
                // The bytes are now in a new page; drop the temp source file.
                try? FileManager.default.removeItem(at: fileURL)
                completion(true)
            case .failure(let error):
                self.recordingFallback(fileURL: fileURL,
                                       reason: error.localizedDescription,
                                       completion: completion)
            }
        }
    }

    // MARK: - Page-creation bridge

    // Wraps a bridge-side failure so it surfaces with a human-readable message.
    private struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Probes whether the global page-creation bridge is registered. False on any throw.
    @MainActor
    func bridgeSupportsPageCreation() async -> Bool {
        do {
            let available = try await webView.callAsyncJavaScript(
                RecordingSupport.createPageBridgeAvailabilityJS,
                arguments: [:], in: nil, contentWorld: .page)
            return (available as? Bool) == true
        } catch {
            return false
        }
    }

    // Lists the spaces the user can write to. Throws BridgeError on not-ok / malformed.
    @MainActor
    func fetchSpaces() async throws -> [RecordingSpace] {
        let result = try await webView.callAsyncJavaScript(
            RecordingSupport.listSpacesJS,
            arguments: [:], in: nil, contentWorld: .page)
        guard let dict = result as? [String: Any], (dict["ok"] as? Bool) == true else {
            let message = ((result as? [String: Any])?["error"] as? String) ?? "Could not load spaces."
            throw BridgeError(message: message)
        }
        let raw = (dict["spaces"] as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return RecordingSpace(id: id, name: name)
        }
    }

    // Lists the pages under a space, or under a parent page when `parentPageId` is set.
    @MainActor
    func fetchPages(spaceId: String, parentPageId: String?) async throws -> [RecordingPageNode] {
        let arguments: [String: Any] = [
            "spaceId": spaceId,
            "parentPageId": parentPageId ?? ""
        ]
        let result = try await webView.callAsyncJavaScript(
            RecordingSupport.listPagesJS,
            arguments: arguments, in: nil, contentWorld: .page)
        guard let dict = result as? [String: Any], (dict["ok"] as? Bool) == true else {
            let message = ((result as? [String: Any])?["error"] as? String) ?? "Could not load pages."
            throw BridgeError(message: message)
        }
        let raw = (dict["pages"] as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            let hasChildren = (entry["hasChildren"] as? Bool) ?? false
            return RecordingPageNode(id: id, title: title, hasChildren: hasChildren)
        }
    }

    // Creates a new page from the recording. Never throws out: returns .failure with a
    // human-readable message so the caller can fall back to Downloads.
    @MainActor
    private func createPageWithRecording(spaceId: String, parentPageId: String?,
                                         title: String, base64: String,
                                         filename: String) async -> Result<Void, Error> {
        let arguments: [String: Any] = [
            "spaceId": spaceId,
            "parentPageId": parentPageId ?? "",
            "title": title,
            "base64": base64,
            "filename": filename,
            "mimeType": RecordingSupport.mimeType
        ]
        do {
            let result = try await webView.callAsyncJavaScript(
                RecordingSupport.createPageWithRecordingJS,
                arguments: arguments, in: nil, contentWorld: .page)
            if let dict = result as? [String: Any], (dict["ok"] as? Bool) == true {
                return .success(())
            }
            let dict = result as? [String: Any]
            let message = (dict?["message"] as? String)
                ?? (dict?["error"] as? String)
                ?? "Creating the recording page failed."
            return .failure(BridgeError(message: message))
        } catch {
            return .failure(error)
        }
    }

    // Saves the recording to Downloads, reveals it in Finder, and explains why a page was
    // not created. `completion(true)` when the file was saved (delivered durably);
    // `completion(false)` when even the Downloads save failed (the recording was lost).
    func recordingFallback(fileURL: URL, reason: String, completion: ((Bool) -> Void)? = nil) {
        let destination = Self.downloadsDestination(for: fileURL.lastPathComponent)
        do {
            // Copy (not move): the copy must succeed before we touch the temp source.
            try FileManager.default.copyItem(at: fileURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            // The bytes are safely in Downloads (the user's kept copy), so remove the
            // temp original to avoid a /tmp leak.
            try? FileManager.default.removeItem(at: fileURL)
            presentImportAlert(
                title: "Recording saved to Downloads",
                text: "\(reason)\n\nThe recording was saved to your Downloads folder instead.")
            completion?(true)
        } catch {
            presentImportAlert(
                title: "Recording could not be saved",
                text: "\(reason)\n\nSaving to Downloads also failed: \(error.localizedDescription)")
            completion?(false)
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
        // target=_blank / window.open: load real targets in the same web view instead of a
        // dead window. Skip blank/empty targets (e.g. window.open('', '_blank')): loading
        // about:blank into the main web view would replace the current page with a blank
        // screen.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           !url.absoluteString.isEmpty,
           url.absoluteString != "about:blank" {
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

    // getUserMedia (e.g. Docmost's voice recording) asks WebKit for microphone/camera
    // access through this delegate. If it is not implemented WebKit denies the request
    // outright. Grant capture for the app's trusted Docmost content; the first real use
    // still triggers the system's microphone/camera prompt, which is gated by the
    // NSMicrophoneUsageDescription / NSCameraUsageDescription keys in Info.plist.
    // Available since macOS 12; the app targets macOS 14, so no availability guard.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A navigation that WebKit flags as a download (e.g. an <a download> link such as
        // the blob URL file-saver uses for Docmost's export). Hand it to WKDownloadDelegate
        // instead of loading it into the frame, which would blank the page.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

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
        let destination = Self.downloadsDestination(for: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    // Resolves a collision-free destination in the user's Downloads directory for a
    // suggested file name. Adds a numeric suffix (e.g. "file 1.pdf") when a file with
    // the same name already exists. Shared by WKDownloadDelegate and the recording
    // fallback so both place files identically.
    static func downloadsDestination(for suggestedFilename: String) -> URL {
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
        return destination
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
