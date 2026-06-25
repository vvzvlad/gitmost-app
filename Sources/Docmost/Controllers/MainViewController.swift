import AppKit
import DocmostCore

// Hosts the tab strip on top and a content container below that shows the selected
// server's persistent web view.
final class MainViewController: NSViewController, NSMenuItemValidation {

    private let store: ServerStore

    // Remembers each server's last visited page so a restart reopens it.
    private let lastLocationStore = LastLocationStore()

    private let tabBar = TabBarView()
    private let pageTabBar = PageTabBarView()
    private let contentContainer = NSView()

    // Two-level tab model. The top strip selects the SERVER; the second strip shows the page
    // ("browser") tabs OF the selected server.
    // Owns both the pure per-server tab model and the id->WebTab lifecycle (so they can never
    // drift), and exposes intent-level operations.
    private let pageTabs = PageTabController()
    // The currently selected SERVER.
    private var selectedServerID: UUID?
    // The web view currently installed in the content container (so we only swap on change).
    private weak var installedContentView: NSView?
    // Drives the page-tab strip's height (0 when hidden, 30 when shown). Assigned in viewDidLoad.
    private var pageTabBarHeightConstraint: NSLayoutConstraint!

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
    var activeTab: WebTab? {
        guard let s = selectedServerID else { return nil }
        return pageTabs.activeWebTab(for: s)
    }

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
        pageTabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        view.addSubview(pageTabBar)
        view.addSubview(contentContainer)

        // The page-tab strip collapses to height 0 (and is hidden) when there is no selected
        // server or that server has no tabs; otherwise it expands to its standard height.
        pageTabBarHeightConstraint = pageTabBar.heightAnchor.constraint(equalToConstant: 30)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),

            pageTabBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pageTabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageTabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageTabBarHeightConstraint,

            contentContainer.topAnchor.constraint(equalTo: pageTabBar.bottomAnchor),
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

        tabBar.onSelect = { [weak self] id in self?.selectServer(id: id) }
        tabBar.onOpenSettings = { [weak self] in self?.openSettings() }
        tabBar.onGoBack = { [weak self] in self?.goBack(nil) }

        pageTabBar.onSelect = { [weak self] tabID in
            guard let self, let s = self.selectedServerID else { return }
            self.selectPageTab(serverID: s, tabID: tabID)
        }
        pageTabBar.onClose = { [weak self] tabID in
            guard let self, let s = self.selectedServerID else { return }
            self.closePageTab(serverID: s, tabID: tabID)
        }
        pageTabBar.onNewTab = { [weak self] in self?.newTab(nil) }

        // Forward each tab's navigation/title changes (the controller tags them with serverID+tabID).
        pageTabs.onNavigationStateChanged = { [weak self] serverID, tabID, webTab in
            guard let self else { return }
            self.persistLocation(of: webTab, serverID: serverID, tabID: tabID)
            // Toggle the Back button only for the visible (selected server + active) tab.
            if self.selectedServerID == serverID, self.pageTabs.activeTab(for: serverID) == tabID {
                self.tabBar.setBackButtonVisible(webTab.showsBackButton)
            }
        }
        pageTabs.onTitleChanged = { [weak self] _, tabID, webTab in
            guard let self else { return }
            self.pageTabBar.updateTitle(id: tabID, title: self.displayTitle(for: webTab))
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(serversDidChange),
                                               name: .serversDidChange,
                                               object: nil)

        // Initial population.
        tabBar.reload(servers: store.servers, selectedID: selectedServerID)
        reloadPageTabBar()
        if let first = store.servers.first {
            selectServer(id: first.id)
        } else {
            updatePlaceholder()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Selection

    // Select a SERVER (top strip). Creates the server's first page tab on demand (restoring
    // the last location), then shows its active page tab and rebuilds both strips.
    func selectServer(id: UUID) {
        guard let server = store.servers.first(where: { $0.id == id }) else { return }

        // Create the server's first page tab lazily, restoring the last visited editable page
        // (never a share/read-only page); else the server root.
        guard let tab = pageTabs.openServer(server, startURL:
                lastLocationStore.load(for: id)
                    .flatMap { server.isInternalPageURL($0) && !server.isSharePageURL($0) ? $0 : nil }
                    ?? server.url
        ) else { return }

        showTab(tab)
        selectedServerID = id
        placeholderLabel.isHidden = true
        tabBar.reload(servers: store.servers, selectedID: id)
        reloadPageTabBar()
    }

    // Switch the active page tab WITHIN the selected server.
    private func selectPageTab(serverID: UUID, tabID: UUID) {
        guard selectedServerID == serverID,
              let tab = pageTabs.selectTab(tabID, in: serverID) else { return }
        showTab(tab)
        reloadPageTabBar()
    }

    // Close a page tab of a server (never the last one). Tears down its web view, updates the
    // model, and — when the closed tab was visible — switches to the new active tab.
    private func closePageTab(serverID: UUID, tabID: UUID) {
        let result = pageTabs.closeTab(tabID, in: serverID)
        guard result.didClose else { return }
        if selectedServerID == serverID {
            if result.closedActiveTab, let newActive = result.newActiveTab {
                showTab(newActive)
            }
            reloadPageTabBar()
        }
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !store.servers.isEmpty
        // No servers => no page tabs; collapse the page strip.
        if store.servers.isEmpty { reloadPageTabBar() }
    }

    // Install a web tab as the visible content and sync the window chrome to it. The single
    // "make this tab visible" path shared by server selection, page-tab selection, new-tab and
    // close-fallthrough.
    private func showTab(_ webTab: WebTab) {
        webTab.loadIfNeeded()
        webTab.setPageZoom(currentZoom)
        setContent(webTab)
        tabBar.setBackButtonVisible(webTab.showsBackButton)
    }

    // Installs `webTab`'s web view into the content container, pinned on all edges. No-op when
    // it is already the installed view.
    private func setContent(_ webTab: WebTab) {
        if installedContentView === webTab.webView { return }
        installedContentView?.removeFromSuperview()

        let webView = webTab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        installedContentView = webView
    }

    // Rebuild the page-tab strip for the selected server (or collapse it when there is none).
    private func reloadPageTabBar() {
        guard let s = selectedServerID, pageTabs.hasTabs(for: s) else {
            pageTabBarHeightConstraint.constant = 0
            pageTabBar.isHidden = true
            return
        }
        pageTabBar.isHidden = false
        pageTabBarHeightConstraint.constant = 30
        let items: [(id: UUID, title: String)] = pageTabs.tabWebPairs(for: s).map {
            (id: $0.id, title: displayTitle(for: $0.webTab))
        }
        pageTabBar.reload(tabs: items,
                          selectedID: pageTabs.activeTab(for: s),
                          showClose: pageTabs.count(for: s) > 1)
    }

    // Up-to-date display name for a server id (reflects renames), falling back to a snapshot.
    private func serverName(for id: UUID, fallback: String) -> String {
        store.servers.first(where: { $0.id == id })?.name ?? fallback
    }

    // Title to show on a page tab: the page's document title, else the (live) server name.
    private func displayTitle(for webTab: WebTab) -> String {
        webTab.pageTitle ?? serverName(for: webTab.server.id, fallback: webTab.server.name)
    }

    // MARK: - Server changes

    @objc private func serversDidChange() {
        let currentServers = store.servers
        let validIDs = Set(currentServers.map { $0.id })

        // Tear down ALL page tabs of servers that were deleted.
        for serverID in pageTabs.serverIDs() where !validIDs.contains(serverID) {
            pageTabs.removeServer(serverID)
            // Forget its saved location so a recreated server with a new id starts clean.
            lastLocationStore.remove(for: serverID)
        }

        // Tear down page tabs whose server URL changed so they reload the new address
        // (lazily recreated on next selection). All tabs of a server share one server.url
        // snapshot, so the representative tab tells us whether the URL changed.
        for server in currentServers {
            if let tab = pageTabs.representativeTab(for: server.id), tab.server.url != server.url {
                pageTabs.removeServer(server.id)
                // The saved page lived on the old host; drop it so we load the new root.
                lastLocationStore.remove(for: server.id)
            }
        }

        // Resolve the selection after deletions / URL changes.
        if let selected = selectedServerID, validIDs.contains(selected) {
            // Selected server still exists; refresh the bar (name may have changed).
            tabBar.reload(servers: currentServers, selectedID: selected)
            // If the selected server's tabs were torn down (its URL changed), rebuild now so
            // the new address is shown immediately.
            if !pageTabs.hasTabs(for: selected) {
                selectedServerID = nil
                selectServer(id: selected)
            } else {
                reloadPageTabBar()
            }
        } else {
            selectedServerID = nil
            if let first = currentServers.first {
                selectServer(id: first.id)
            } else {
                tabBar.reload(servers: currentServers, selectedID: nil)
                updatePlaceholder()
                tabBar.setBackButtonVisible(false)
                reloadPageTabBar()
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

        let controller = SettingsWindowController(
            store: store,
            destinationStore: RecordingDestinationStore(),
            selectedServerId: selectedServerID,
            fetchSpaces: { [weak self] serverId in
                await self?.recordingFetchSpaces(serverId: serverId) ?? []
            },
            fetchPages: { [weak self] serverId, spaceId, parentPageId in
                await self?.recordingFetchPages(serverId: serverId, spaceId: spaceId, parentPageId: parentPageId) ?? []
            },
            bridgeReady: { [weak self] serverId in
                await self?.recordingBridgeReady(serverId: serverId) ?? false
            }
        )
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
        activeTab?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        activeTab?.goBack()
    }

    // Save the tab's current URL as the server's last location, but only for the server's
    // ACTIVE tab and only for real editable internal pages — never an external/redirect page,
    // never about:blank, and never a read-only public "share" page.
    private func persistLocation(of tab: WebTab, serverID: UUID, tabID: UUID) {
        guard pageTabs.activeTab(for: serverID) == tabID else { return }
        guard let url = tab.webView.url,
              tab.server.isInternalPageURL(url),
              !tab.server.isSharePageURL(url) else { return }
        lastLocationStore.save(url, for: serverID)
    }

    @objc func goForward(_ sender: Any?) {
        activeTab?.goForward()
    }

    // Opens a NEW page tab of the currently selected server, at the server ROOT (not the last
    // visited location), and makes it active.
    @objc func newTab(_ sender: Any?) {
        guard let serverID = selectedServerID,
              let server = store.servers.first(where: { $0.id == serverID }) else { return }
        let tab = pageTabs.newTab(for: server, at: server.url)
        showTab(tab)
        reloadPageTabBar()
    }

    @objc func closeTab(_ sender: Any?) {
        // Close the active page tab when the server has more than one; otherwise fall back to
        // closing the window, preserving the historical ⌘W = Close Window behavior.
        if let s = selectedServerID, pageTabs.count(for: s) > 1,
           let active = pageTabs.activeTab(for: s) {
            closePageTab(serverID: s, tabID: active)
        } else {
            view.window?.performClose(sender)
        }
    }

    private func applyZoomToAllTabs() {
        for tab in pageTabs.allWebTabs { tab.setPageZoom(currentZoom) }
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

    // Delivers a finished recording to the destination configured in Settings: it always
    // creates a NEW "Recording <timestamp>" child page under the configured space/parent
    // (regardless of which page, if any, is open) and inserts the recording there. If no
    // destination is set, or the destination server's tab/bridge is unavailable, the file
    // is saved to Downloads instead — the recording is never lost. Wired from AppDelegate as
    // RecordingController.shared.deliverFile. `completion` reports whether the recording was
    // delivered somewhere durable; it fires exactly once on the main thread.
    func deliverRecording(_ url: URL, completion: @escaping (Bool) -> Void) {
        let store = RecordingDestinationStore()
        guard let dest = store.destination else {
            saveToDownloads(url,
                            reason: "No recording destination is set. Choose one in Settings.",
                            completion: completion)
            return
        }
        guard let tab = pageTabs.representativeTab(for: dest.serverId) else {
            // Only loaded tabs can serve the page-creation bridge; the destination server
            // must be open in a tab for the recording to become a page.
            saveToDownloads(url,
                            reason: "Open the destination server's tab first, then record.",
                            completion: completion)
            return
        }
        tab.createRecordingPage(spaceId: dest.spaceId,
                                parentPageId: dest.parentPageId,
                                title: RecordingSupport.recordingPageTitle(for: Date()),
                                fileURL: url,
                                completion: completion)
    }

    // Saves a recording to Downloads when no page could be created, explains why in an
    // alert, and reveals it in Finder. Routes through any loaded tab's recordingFallback
    // when one exists (so the file lands identically to a normal download); otherwise does
    // a minimal inline Downloads copy. `completion(true)` on a durable save, `completion(false)`
    // only when even the Downloads copy fails. Main-thread; fires completion exactly once.
    private func saveToDownloads(_ url: URL, reason: String, completion: @escaping (Bool) -> Void) {
        // Prefer any loaded tab's fallback (shared alert + Downloads placement).
        if let tab = pageTabs.allWebTabs.first {
            tab.recordingFallback(fileURL: url, reason: reason, completion: completion)
            return
        }

        // No tab at all: do a minimal inline Downloads copy + reveal via the shared helper.
        if WebTab.copyRecordingToDownloads(url) != nil {
            presentAlert(title: "Recording saved to Downloads",
                         text: "\(reason)\n\nThe recording was saved to your Downloads folder instead.")
            completion(true)
        } else {
            presentAlert(title: "Recording could not be saved",
                         text: "\(reason)\n\nSaving to Downloads also failed.")
            completion(false)
        }
    }

    // MARK: - Recording destination data providers (for the Settings chooser)

    // These route to a server's loaded WebTab. Only loaded tabs can serve the bridge, so an
    // unopened server yields empty lists / not-ready (the chooser shows the appropriate alert).

    // Lists the spaces the user can write to on the given server. Empty on nil/throw.
    func recordingFetchSpaces(serverId: UUID) async -> [RecordingSpace] {
        guard let tab = pageTabs.representativeTab(for: serverId) else { return [] }
        return (try? await tab.fetchSpaces()) ?? []
    }

    // Lists the pages under a space (or under a parent page) on the given server.
    func recordingFetchPages(serverId: UUID, spaceId: String, parentPageId: String?) async -> [RecordingPageNode] {
        guard let tab = pageTabs.representativeTab(for: serverId) else { return [] }
        return (try? await tab.fetchPages(spaceId: spaceId, parentPageId: parentPageId)) ?? []
    }

    // True when the given server's page-creation bridge is ready (its tab is loaded).
    func recordingBridgeReady(serverId: UUID) async -> Bool {
        await pageTabs.representativeTab(for: serverId)?.bridgeSupportsPageCreation() ?? false
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
            // Treat ANY non-idle phase (recording/paused/saving/done/failed) as "active":
            // "Stop Recording" then, else "Start Recording".
            menuItem.title = controller.phase == .idle ? "Start Recording" : "Stop Recording"
            // Stopping must always be possible; only starting needs an open page. (While
            // saving/done/failed, toggle() is a no-op, but the title stays "Stop Recording".)
            return controller.isSupported
                && (controller.phase != .idle || activeTab != nil)
        }
        if menuItem.action == #selector(togglePauseRecording(_:)) {
            // "Resume Recording" while paused, else "Pause Recording".
            menuItem.title = controller.phase == .paused ? "Resume Recording" : "Pause Recording"
            // Pause/resume is only meaningful while actively recording or paused (not while
            // saving/done/failed, where there is no live capture to pause).
            return controller.isSupported
                && (controller.phase == .recording || controller.phase == .paused)
        }
        if menuItem.action == #selector(closeTab(_:)) {
            // ⌘W is always live: it closes the active page tab when several exist, otherwise it
            // closes the window (browser/macOS behavior).
            return true
        }
        if menuItem.action == #selector(newTab(_:)) {
            return selectedServerID != nil
        }
        // Leave every other menu item enabled (default responder-chain behavior).
        return true
    }
}
