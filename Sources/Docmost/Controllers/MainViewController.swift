import AppKit

// Hosts the tab strip on top and a content container below that shows the selected
// server's persistent web view.
final class MainViewController: NSViewController {

    private let store: ServerStore

    private let tabBar = TabBarView()
    private let contentContainer = NSView()

    // Lazily created, kept-alive web tabs keyed by server id.
    private var tabs: [UUID: WebTab] = [:]
    private var selectedID: UUID?

    // Placeholder shown when there are no servers configured.
    private let placeholderLabel = NSTextField(labelWithString:
        "Нет добавленных серверов. Откройте «Серверы…», чтобы добавить.")

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

    @objc func addServer(_ sender: Any?) {
        presentSettings(thenAddServer: true)
    }
}
