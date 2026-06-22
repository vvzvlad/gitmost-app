import AppKit
import DocmostCore

// Hosts the tab strip on top and a content container below that shows the selected
// server's persistent web view.
final class MainViewController: NSViewController, NSMenuItemValidation {

    private let store: ServerStore

    // Remembers each server's last visited page so a restart reopens it.
    private let lastLocationStore = LastLocationStore()

    private let tabBar = TabBarView()
    private let contentContainer = NSView()

    // Lazily created, kept-alive web tabs keyed by server id.
    private var tabs: [UUID: WebTab] = [:]
    private var selectedID: UUID?

    // App-wide page zoom, applied to every tab and persisted across launches.
    private static let zoomDefaultsKey = "pageZoom"
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 3.0
    private static let zoomStep: CGFloat = 0.1
    private var currentZoom: CGFloat = 1.0

    // Placeholder shown when there are no servers configured.
    private let placeholderLabel = NSTextField(labelWithString:
        "No servers configured. Open “Servers…” to add one.")

    // Settings window controller is held strongly while presented.
    private var settingsWindowController: SettingsWindowController?

    // Meeting recorder. Stored as AnyObject because AudioRecorder is @available(macOS
    // 14.2, *) and this class targets macOS 14.0; created on demand inside an
    // availability guard. `isRecording` is the re-entrancy guard / menu-title source.
    private var audioRecorder: AnyObject?
    private var isRecording = false
    // True from the moment a stop is initiated until its completion runs, so a second
    // ⌘⇧R while a recording is being finalized is ignored (no bogus "Recording failed").
    private var isStopping = false

    // The currently visible web tab, if any.
    private var activeTab: WebTab? { selectedID.flatMap { tabs[$0] } }

    init(store: ServerStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        // Build the root view programmatically.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Restore the saved zoom; UserDefaults.double returns 0 when unset, so fall back to 1.0.
        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomDefaultsKey)
        currentZoom = savedZoom > 0 ? CGFloat(savedZoom) : 1.0

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Centered placeholder for the empty state.
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        contentContainer.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor)
        ])

        tabBar.onSelect = { [weak self] id in self?.select(id: id) }
        tabBar.onOpenSettings = { [weak self] in self?.openSettings() }
        tabBar.onGoBack = { [weak self] in self?.goBack(nil) }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(serversDidChange),
                                               name: .serversDidChange,
                                               object: nil)

        // Initial population.
        tabBar.reload(servers: store.servers, selectedID: selectedID)
        if let first = store.servers.first {
            select(id: first.id)
        } else {
            updatePlaceholder()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Selection

    func select(id: UUID) {
        guard let server = store.servers.first(where: { $0.id == id }) else { return }

        // Create the web tab lazily and keep it alive afterwards.
        let tab: WebTab
        if let existing = tabs[id] {
            tab = existing
        } else {
            // Reopen the last visited editable page if we have a valid one; else the root.
            // Share (read-only) pages are never restored.
            let startURL = lastLocationStore.load(for: id)
                .flatMap { server.isInternalPageURL($0) && !server.isSharePageURL($0) ? $0 : nil }
                ?? server.url
            tab = WebTab(server: server, startURL: startURL,
                         customJS: UserScripts.js, customCSS: UserScripts.css)
            tab.onNavigationStateChanged = { [weak self, weak tab] in
                guard let self, let tab else { return }
                // Remember the latest internal location for next launch.
                self.persistLocation(of: tab, serverID: id)
                // Toggle the Back button only for the visible tab.
                if self.selectedID == id {
                    self.tabBar.setBackButtonVisible(tab.showsBackButton)
                }
            }
            tabs[id] = tab
        }
        tab.loadIfNeeded()
        // Apply the current zoom so new and existing tabs match the app-wide setting.
        tab.setPageZoom(currentZoom)

        // Swap the visible web view inside the content container.
        if let current = selectedID, let currentTab = tabs[current], currentTab.webView.superview === contentContainer {
            currentTab.webView.removeFromSuperview()
        }

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        selectedID = id
        placeholderLabel.isHidden = true
        tabBar.reload(servers: store.servers, selectedID: id)
        // Reflect the selected tab's current location (each tab has its own URL/history).
        tabBar.setBackButtonVisible(tab.showsBackButton)
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !store.servers.isEmpty
    }

    // MARK: - Server changes

    @objc private func serversDidChange() {
        let currentServers = store.servers
        let validIDs = Set(currentServers.map { $0.id })

        // Tear down web tabs whose server was deleted.
        for (id, tab) in tabs where !validIDs.contains(id) {
            tab.tearDown()
            tabs.removeValue(forKey: id)
            // Forget its saved location so a recreated server with a new id starts clean.
            lastLocationStore.remove(for: id)
        }

        // Tear down web tabs whose server URL changed so they reload the new address
        // (lazily recreated on next selection).
        for server in currentServers {
            if let tab = tabs[server.id], tab.server.url != server.url {
                tab.tearDown()
                tabs.removeValue(forKey: server.id)
                // The saved page lived on the old host; drop it so we load the new root.
                lastLocationStore.remove(for: server.id)
            }
        }

        // Resolve the selection after deletions.
        if let selected = selectedID, validIDs.contains(selected) {
            // Selected server still exists; refresh the bar (name may have changed).
            tabBar.reload(servers: currentServers, selectedID: selected)
            // If the selected tab was torn down (its URL changed), rebuild it now so the
            // new address is shown immediately.
            if tabs[selected] == nil {
                selectedID = nil
                select(id: selected)
            }
        } else {
            selectedID = nil
            if let first = currentServers.first {
                select(id: first.id)
            } else {
                tabBar.reload(servers: currentServers, selectedID: nil)
                updatePlaceholder()
                tabBar.setBackButtonVisible(false)
            }
        }
    }

    // MARK: - Settings

    @objc func openSettings() {
        presentSettings(thenAddServer: false)
    }

    private func presentSettings(thenAddServer: Bool) {
        // If the settings sheet is already presented, just route an add request to it.
        if let existing = settingsWindowController {
            if thenAddServer { existing.beginAddServer() }
            return
        }

        let controller = SettingsWindowController(store: store)
        settingsWindowController = controller

        guard let window = view.window, let sheet = controller.window else {
            controller.showWindow(nil)
            if thenAddServer { controller.beginAddServer() }
            return
        }

        window.beginSheet(sheet) { [weak self] _ in
            // Release the controller once the sheet dismisses so it rebuilds fresh next time.
            self?.settingsWindowController = nil
        }

        if thenAddServer {
            // Defer until the settings sheet has finished presenting before stacking
            // the add-editor sheet on top of it.
            DispatchQueue.main.async { [weak controller] in
                controller?.beginAddServer()
            }
        }
    }

    // MARK: - Menu actions (responder chain targets)

    @objc func reloadCurrent(_ sender: Any?) {
        if let id = selectedID { tabs[id]?.reload() }
    }

    @objc func goBack(_ sender: Any?) {
        if let id = selectedID { tabs[id]?.goBack() }
    }

    // Save the tab's current URL as the server's last location, but only for real
    // editable internal pages — never an external/redirect page, never about:blank,
    // and never a read-only public "share" page.
    private func persistLocation(of tab: WebTab, serverID: UUID) {
        guard let url = tab.webView.url,
              tab.server.isInternalPageURL(url),
              !tab.server.isSharePageURL(url) else { return }
        lastLocationStore.save(url, for: serverID)
    }

    @objc func goForward(_ sender: Any?) {
        if let id = selectedID { tabs[id]?.goForward() }
    }

    private func applyZoomToAllTabs() {
        for tab in tabs.values { tab.setPageZoom(currentZoom) }
    }

    private func setZoom(_ factor: CGFloat) {
        // Clamp and round to a clean 0.1 step to avoid float drift.
        let clamped = min(max(factor, Self.minZoom), Self.maxZoom)
        currentZoom = (clamped * 10).rounded() / 10
        applyZoomToAllTabs()
        UserDefaults.standard.set(Double(currentZoom), forKey: Self.zoomDefaultsKey)
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(currentZoom + Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setZoom(currentZoom - Self.zoomStep) }
    @objc func zoomReset(_ sender: Any?) { setZoom(1.0) }

    @objc func addServer(_ sender: Any?) {
        presentSettings(thenAddServer: true)
    }

    // MARK: - Recording

    // Starts or stops a meeting recording (system audio + microphone). Gated to macOS
    // 14.2+ (Core Audio process-tap API). The finished file is delivered into the open
    // page via the gitmost JS bridge, falling back to Downloads when unavailable.
    @objc func toggleRecording(_ sender: Any?) {
        guard #available(macOS 14.2, *) else {
            presentRecordingAlert(title: "Recording unavailable",
                                  text: "Recording requires macOS 14.2 or later.")
            return
        }

        // Ignore input while a stop is finalizing: this prevents a second ⌘⇧R from
        // re-entering stopRecording() (bogus failure) or starting a new recording before
        // the previous one has finished tearing down.
        if isStopping { return }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @available(macOS 14.2, *)
    private func startRecording() {
        // Need an open page so we have somewhere to deliver the result; the WebTab
        // handles bridge-absence, but with no tab at all there is no destination.
        guard activeTab != nil else {
            presentRecordingAlert(title: "No page open",
                                  text: "Open a gitmost page first, then start recording.")
            return
        }

        let recorder = AudioRecorder()
        do {
            try recorder.start()
            audioRecorder = recorder
            isRecording = true
        } catch {
            audioRecorder = nil
            presentRecordingAlert(title: "Could not start recording",
                                  text: error.localizedDescription)
        }
    }

    @available(macOS 14.2, *)
    private func stopRecording() {
        guard let recorder = audioRecorder as? AudioRecorder else {
            isRecording = false
            return
        }
        // Flip all state SYNCHRONOUSLY before calling stop(), so a second ⌘⇧R that arrives
        // before the completion runs can neither re-enter stopRecording() (the recorder is
        // already cleared) nor start a fresh recording (isStopping/isRecording block it).
        //
        // INVARIANT: AudioRecorder.stop's completion MUST be invoked exactly once (on every
        // path), or isStopping would stay true and permanently disable the recording command.
        isStopping = true
        isRecording = false
        audioRecorder = nil

        recorder.stop { [weak self] result in
            // AudioRecorder calls completion synchronously on the calling thread; hop to
            // the main actor to touch UI / the active tab safely.
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStopping = false
                switch result {
                case .success(let url):
                    if let tab = self.activeTab {
                        tab.insertRecording(fileURL: url)
                    } else {
                        // The page closed mid-recording: nothing to insert into. Surface
                        // the temp location so the file is not lost.
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                case .failure(let error):
                    self.presentRecordingAlert(title: "Recording failed",
                                               text: error.localizedDescription)
                }
            }
        }
    }

    private func presentRecordingAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Menu validation

    // Keeps the recording menu item's title in sync with state; leaves all other items
    // enabled (this class otherwise relies on the default responder-chain validation).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleRecording(_:)) {
            menuItem.title = isRecording ? "Stop Recording" : "Start Recording"
            // Enabled only when recording is actually possible: macOS 14.2+ (process-tap
            // API) AND an open page to deliver the result into. Greyed out otherwise.
            if #available(macOS 14.2, *) {
                return activeTab != nil
            }
            return false
        }
        // Leave every other menu item enabled (default responder-chain behavior).
        return true
    }
}
