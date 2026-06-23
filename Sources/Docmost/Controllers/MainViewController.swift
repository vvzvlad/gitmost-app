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

    // The currently visible web tab, if any. Internal so the app wiring (AppDelegate's
    // RecordingController closures) can query whether a page is available / deliver into it.
    var activeTab: WebTab? { selectedID.flatMap { tabs[$0] } }

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

    // The recording state machine now lives in RecordingController.shared (a single,
    // app-level source of truth shared by the menu, and — in Stage B — the floating panel
    // and menu-bar item). These responder-chain actions just drive that controller.

    // Starts or stops a meeting recording (system audio + microphone).
    @objc func toggleRecording(_ sender: Any?) {
        RecordingController.shared.toggle()
    }

    // Pauses an active recording, or resumes a paused one.
    @objc func togglePauseRecording(_ sender: Any?) {
        switch RecordingController.shared.state {
        case .recording:
            RecordingController.shared.pause()
        case .paused:
            RecordingController.shared.resume()
        case .idle:
            break
        }
    }

    // Delivers a finished recording into the open page (via the gitmost JS bridge), or —
    // if the page closed mid-recording — reveals the temp file so it is not lost. Wired
    // from AppDelegate as RecordingController.shared.deliverFile.
    func deliverRecording(_ url: URL) {
        if let tab = activeTab {
            tab.insertRecording(fileURL: url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // Generic alert helper, reused by AppDelegate's RecordingController.presentError wiring.
    func presentAlert(title: String, text: String) {
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

    // Keeps the recording menu items' titles in sync with RecordingController state; leaves
    // all other items enabled (this class otherwise relies on default responder-chain
    // validation).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controller = RecordingController.shared
        if menuItem.action == #selector(toggleRecording(_:)) {
            // "Stop Recording" while recording or paused, else "Start Recording".
            menuItem.title = controller.state == .idle ? "Start Recording" : "Stop Recording"
            // Stopping must always be possible; only starting needs an open page.
            return controller.isSupported
                && (controller.state != .idle || activeTab != nil)
        }
        if menuItem.action == #selector(togglePauseRecording(_:)) {
            // "Resume Recording" while paused, else "Pause Recording".
            menuItem.title = controller.state == .paused ? "Resume Recording" : "Pause Recording"
            // Only meaningful while a recording is active (recording or paused).
            return controller.isSupported && controller.state != .idle
        }
        // Leave every other menu item enabled (default responder-chain behavior).
        return true
    }
}
