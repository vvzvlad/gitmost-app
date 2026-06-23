import AppKit
import DocmostCore

// Manages the list of servers: a table with Name/URL columns plus add/remove/edit.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: ServerStore
    private let tableView = NSTableView()

    private let removeButton = NSButton()
    private let editButton = NSButton()

    // Recording-destination wiring (injected by MainViewController).
    private let destinationStore: RecordingDestinationStore
    private let selectedServerId: UUID?
    private let fetchSpaces: (UUID) async -> [RecordingSpace]
    private let fetchPages: (UUID, String, String?) async -> [RecordingPageNode]
    private let bridgeReady: (UUID) async -> Bool

    // Recording-feature gate (default OFF). The whole section below is inert until enabled.
    private let featureStore = RecordingFeatureStore()
    private let enableRecordingCheckbox = NSButton()

    // Recording-destination UI.
    private let destinationLabel = NSTextField(labelWithString: "")
    private let setDestinationButton = NSButton()
    private let clearDestinationButton = NSButton()

    // Strong reference to the active destination chooser sheet while it is up.
    private var destinationChooser: RecordingDestinationChooser?

    // Private pasteboard type used only for intra-table drag-to-reorder of servers.
    private let serverRowType = NSPasteboard.PasteboardType("com.docmost.settings.server-row")

    init(store: ServerStore,
         destinationStore: RecordingDestinationStore,
         selectedServerId: UUID?,
         fetchSpaces: @escaping (UUID) async -> [RecordingSpace],
         fetchPages: @escaping (UUID, String, String?) async -> [RecordingPageNode],
         bridgeReady: @escaping (UUID) async -> Bool) {
        self.store = store
        self.destinationStore = destinationStore
        self.selectedServerId = selectedServerId
        self.fetchSpaces = fetchSpaces
        self.fetchPages = fetchPages
        self.bridgeReady = bridgeReady

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Servers"

        super.init(window: window)

        buildUI()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadTable),
                                               name: .serversDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(recordingFeatureDidChange),
                                               name: .recordingFeatureDidChange,
                                               object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Scrollable table with two columns.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 180
        let urlColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlColumn.title = "Address"
        urlColumn.width = 320

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(urlColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.registerForDraggedTypes([serverRowType])
        tableView.draggingDestinationFeedbackStyle = .gap
        scrollView.documentView = tableView

        // Action buttons.
        let addButton = NSButton(title: "+", target: self, action: #selector(addNew))
        addButton.bezelStyle = .rounded

        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)

        editButton.title = "Edit…"
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelected)

        let closeButton = NSButton(title: "Done", target: self, action: #selector(closeSettings))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [addButton, removeButton, editButton, NSView(), closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // Recording-destination section (where every recording becomes a new page).
        let destinationBox = buildDestinationSection()

        contentView.addSubview(scrollView)
        contentView.addSubview(buttonStack)
        contentView.addSubview(destinationBox)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            destinationBox.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 16),
            destinationBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            destinationBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            // Extra bottom breathing room so the box does not sit flush against the window edge.
            destinationBox.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        updateButtonState()
        updateRecordingFeatureUI()
    }

    // Builds the "Meeting recording" box: a feature on/off checkbox plus the destination row
    // (a read-only label and Set… / Clear buttons). The destination controls are gated on the
    // checkbox so they are inert while the feature is off.
    private func buildDestinationSection() -> NSView {
        let box = NSBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.title = "Meeting recording"
        box.titlePosition = .atTop

        // The feature on/off toggle (default OFF). Flipping it adds/removes the app surfaces live.
        enableRecordingCheckbox.setButtonType(.switch)
        enableRecordingCheckbox.title = "Enable meeting recording"
        enableRecordingCheckbox.target = self
        enableRecordingCheckbox.action = #selector(toggleFeature(_:))
        enableRecordingCheckbox.translatesAutoresizingMaskIntoConstraints = false

        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        destinationLabel.lineBreakMode = .byTruncatingTail
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setDestinationButton.title = "Set…"
        setDestinationButton.bezelStyle = .rounded
        setDestinationButton.target = self
        setDestinationButton.action = #selector(setDestination)

        clearDestinationButton.title = "Clear"
        clearDestinationButton.bezelStyle = .rounded
        clearDestinationButton.target = self
        clearDestinationButton.action = #selector(clearDestination)

        let destinationRow = NSStackView(views: [destinationLabel, setDestinationButton, clearDestinationButton])
        destinationRow.orientation = .horizontal
        destinationRow.spacing = 8
        destinationRow.translatesAutoresizingMaskIntoConstraints = false

        // Vertical stack: the toggle above the destination row.
        let vstack = NSStackView(views: [enableRecordingCheckbox, destinationRow])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8
        vstack.translatesAutoresizingMaskIntoConstraints = false

        box.contentView?.addSubview(vstack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                vstack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                vstack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                vstack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                vstack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
                // Stretch the destination row to the box width so the label can expand.
                destinationRow.trailingAnchor.constraint(equalTo: vstack.trailingAnchor)
            ])
        }
        return box
    }

    // Reflects the current destination in the label and toggles the Clear button. Clear requires
    // BOTH a configured destination AND the feature enabled.
    private func refreshDestinationLabel() {
        let current = destinationStore.destination
        destinationLabel.stringValue = current?.displayLabel ?? "Not set"
        clearDestinationButton.isEnabled = (current != nil) && featureStore.isEnabled
    }

    // Toggles the recording feature on/off (persisted) and broadcasts the change so AppDelegate
    // adds/removes the panel + menu-bar item live, then refreshes this section's controls.
    @objc private func toggleFeature(_ sender: NSButton) {
        featureStore.setEnabled(sender.state == .on)
        // Broadcast so AppDelegate adds/removes the panel + menu-bar item live.
        NotificationCenter.default.post(name: .recordingFeatureDidChange, object: nil)
        updateRecordingFeatureUI()
    }

    // Reflects the feature flag in the checkbox and enables/disables the destination controls.
    private func updateRecordingFeatureUI() {
        // Capture is impossible on macOS < 14.2 and no Start affordance is ever created there,
        // so disable the checkbox (enabling the feature would do nothing).
        let supported = RecordingController.shared.isSupported
        enableRecordingCheckbox.isEnabled = supported
        enableRecordingCheckbox.toolTip = supported ? nil : "Recording requires macOS 14.2 or later."
        let enabled = featureStore.isEnabled
        enableRecordingCheckbox.state = enabled ? .on : .off
        setDestinationButton.isEnabled = enabled
        destinationLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        refreshDestinationLabel()   // also toggles Clear based on enabled + presence
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return store.servers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.servers.indices.contains(row), let column = tableColumn else { return nil }
        let server = store.servers[row]

        let identifier = NSUserInterfaceItemIdentifier("cell_\(column.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField
            cell.identifier = identifier
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        if column.identifier.rawValue == "name" {
            cell.textField?.stringValue = server.name
        } else {
            cell.textField?.stringValue = server.url.absoluteString
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    // MARK: - Drag-to-reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Encode the source row so acceptDrop knows which server is being moved.
        let item = NSPasteboardItem()
        item.setString(String(row), forType: serverRowType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Allow dropping only between rows (a gap), never onto a row.
        return dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let raw = item.string(forType: serverRowType),
              let sourceRow = Int(raw) else { return false }
        // Ignore drops that would not change the order (same slot, or the gap right after itself).
        guard sourceRow != row, sourceRow != row - 1 else { return false }

        // Remember the dragged server so we can keep it selected after the reload.
        let movedID = store.servers.indices.contains(sourceRow) ? store.servers[sourceRow].id : nil
        store.move(from: sourceRow, to: row)   // posts .serversDidChange -> reloadTable()
        if let movedID, let newIndex = store.servers.firstIndex(where: { $0.id == movedID }) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        }
        return true
    }

    private func updateButtonState() {
        let hasSelection = tableView.selectedRow >= 0
        removeButton.isEnabled = hasSelection
        editButton.isEnabled = hasSelection
    }

    @objc private func reloadTable() {
        tableView.reloadData()
        updateButtonState()
    }

    // Reflects a feature-flag change posted elsewhere (e.g. the menu-bar surface) so the
    // checkbox never goes stale. Idempotent: updateRecordingFeatureUI() posts nothing.
    @objc private func recordingFeatureDidChange() {
        updateRecordingFeatureUI()
    }

    // MARK: - Actions

    @objc private func addNew() {
        beginAddServer()
    }

    // Public entry point so the menu / "Add Server…" can open the add sheet.
    func beginAddServer() {
        presentEditor(title: "New Server", name: "", urlString: "") { [weak self] name, urlString in
            self?.store.add(name: name, urlString: urlString)
        }
    }

    @objc private func editSelected() {
        let row = tableView.selectedRow
        guard store.servers.indices.contains(row) else { return }
        let server = store.servers[row]
        presentEditor(title: "Edit Server",
                      name: server.name,
                      urlString: server.url.absoluteString) { [weak self] name, urlString in
            guard let url = ServerStore.normalizeURL(urlString) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmed.isEmpty ? (url.host ?? urlString) : trimmed
            self?.store.update(Server(id: server.id, name: finalName, url: url))
        }
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard store.servers.indices.contains(row) else { return }
        let server = store.servers[row]

        let alert = NSAlert()
        alert.messageText = "Delete server “\(server.name)”?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.store.remove(id: server.id)
            }
        }

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @objc private func closeSettings() {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - Recording destination

    // Presents the unified destination chooser spanning all configured servers. Spaces and
    // pages are fetched lazily per server from inside the chooser, so no pre-fetch happens
    // here; "server not ready" / "no spaces" now surface as info rows inside the tree.
    @objc private func setDestination() {
        guard !store.servers.isEmpty else {
            presentInfoAlert(title: "No server", text: "Add a server first.")
            return
        }
        let current = destinationStore.destination
        // Preselect the saved destination's server, else the active tab's server.
        let initialServerId = current?.serverId ?? selectedServerId
        let chooser = RecordingDestinationChooser(
            servers: store.servers,
            initialServerId: initialServerId,
            initialSpaceId: current?.spaceId,
            initialParentPageId: current?.parentPageId,
            bridgeReady: { [weak self] serverId in await self?.bridgeReady(serverId) ?? false },
            loadSpaces: { [weak self] serverId in await self?.fetchSpaces(serverId) ?? [] },
            loadPages: { [weak self] serverId, spaceId, parentPageId in
                await self?.fetchPages(serverId, spaceId, parentPageId) ?? []
            },
            onConfirm: { [weak self] serverId, spaceId, spaceName, parentPageId, parentTitle in
                guard let self else { return }
                self.destinationStore.save(RecordingDestination(
                    serverId: serverId, spaceId: spaceId, spaceName: spaceName,
                    parentPageId: parentPageId, parentTitle: parentTitle))
                self.refreshDestinationLabel()
            },
            onCancel: {}
        )
        presentDestinationChooser(chooser)
    }

    // Presents the chooser as a sheet on the settings window; releases it on dismissal.
    private func presentDestinationChooser(_ chooser: RecordingDestinationChooser) {
        destinationChooser = chooser
        guard let window = window, let sheet = chooser.window else {
            // No host window to present on: drop the reference rather than leak it.
            destinationChooser = nil
            return
        }
        window.beginSheet(sheet) { [weak self] _ in
            self?.destinationChooser = nil
        }
    }

    @objc private func clearDestination() {
        destinationStore.clear()
        refreshDestinationLabel()
    }

    // A simple informational alert (sheet on the settings window when available).
    private func presentInfoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Add / edit sheet

    // Presents a small form with Name and URL fields. Validates the URL on confirm.
    private func presentEditor(title: String,
                               name: String,
                               urlString: String,
                               onConfirm: @escaping (String, String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        nameField.placeholderString = "Name"
        nameField.stringValue = name

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        urlField.placeholderString = "https://docs.example.com"
        urlField.stringValue = urlString

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        accessory.addSubview(nameField)
        accessory.addSubview(urlField)
        alert.accessoryView = accessory

        // Put keyboard focus on the first field when the editor opens.
        alert.window.initialFirstResponder = nameField

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let enteredURL = urlField.stringValue
            // Validate before saving; show an error and keep the editor logic simple.
            guard ServerStore.normalizeURL(enteredURL) != nil else {
                self?.showInvalidURLAlert()
                return
            }
            onConfirm(nameField.stringValue, enteredURL)
        }

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func showInvalidURLAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid URL"
        alert.informativeText = "Check the server address and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
