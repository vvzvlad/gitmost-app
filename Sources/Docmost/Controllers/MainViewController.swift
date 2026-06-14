import AppKit
import DocmostCore

// Hosts the tab strip on top and a content container below that shows the selected
// server's persistent web view.
final class MainViewController: NSViewController {

    private let store: ServerStore

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
            tab = WebTab(server: server)
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
        }

        // Tear down web tabs whose server URL changed so they reload the new address
        // (lazily recreated on next selection).
        for server in currentServers {
            if let tab = tabs[server.id], tab.server.url != server.url {
                tab.tearDown()
                tabs.removeValue(forKey: server.id)
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
}
