import AppKit
import DocmostCore

// A modal sheet that lets the user choose the recording destination in Settings from a
// SINGLE unified tree spanning ALL configured servers:
//
//     Server → Space → Pages tree → (parent page)
//
// Selecting a Space node picks that server + space root (parentPageId == nil); selecting a
// Page node picks that server + space + that page as the parent. Server nodes and
// informational rows are NOT selectable. Programmatic AppKit (no nibs). It only chooses
// where future recordings land — every finished recording then creates a NEW
// "Recording <timestamp>" child page there.
//
// Lifecycle: the Settings window holds a strong reference while the sheet is up and
// clears it on confirm/cancel/teardown. Confirm and cancel each fire EXACTLY ONCE,
// guarded by the private `didFinish` flag.
final class RecordingDestinationChooser: NSWindowController {

    // A node in the destination outline. Reference type so the outline view can hold and
    // mutate the same instances across reloads (lazy children, loading state).
    private final class Node {
        enum Kind { case server, space, page, info }

        let kind: Kind
        let title: String
        // Context carried down so any node can fetch its children and build the destination.
        let serverId: UUID?
        let serverName: String?
        let spaceId: String?
        let spaceName: String?
        let pageId: String?
        var hasChildren: Bool
        var children: [Node]?     // nil = not loaded yet
        var isLoading = false

        var isSelectable: Bool { kind == .space || kind == .page }

        // Designated initializer — factories below fill in only the relevant context.
        init(kind: Kind, title: String, serverId: UUID?, serverName: String?,
             spaceId: String?, spaceName: String?, pageId: String?, hasChildren: Bool) {
            self.kind = kind
            self.title = title
            self.serverId = serverId
            self.serverName = serverName
            self.spaceId = spaceId
            self.spaceName = spaceName
            self.pageId = pageId
            self.hasChildren = hasChildren
        }

        static func server(id: UUID, name: String) -> Node {
            Node(kind: .server, title: name, serverId: id, serverName: name,
                 spaceId: nil, spaceName: nil, pageId: nil, hasChildren: true)
        }

        static func space(serverId: UUID, serverName: String, id: String, name: String) -> Node {
            Node(kind: .space, title: name, serverId: serverId, serverName: serverName,
                 spaceId: id, spaceName: name, pageId: nil, hasChildren: true)
        }

        static func page(serverId: UUID, serverName: String, spaceId: String, spaceName: String,
                         id: String, title: String, hasChildren: Bool) -> Node {
            Node(kind: .page, title: title, serverId: serverId, serverName: serverName,
                 spaceId: spaceId, spaceName: spaceName, pageId: id, hasChildren: hasChildren)
        }

        static func info(_ text: String) -> Node {
            Node(kind: .info, title: text, serverId: nil, serverName: nil,
                 spaceId: nil, spaceName: nil, pageId: nil, hasChildren: false)
        }
    }

    private let initialServerId: UUID?
    private let initialSpaceId: String?
    private let initialParentPageId: String?
    private let bridgeReady: (_ serverId: UUID) async -> Bool
    private let loadSpaces: (_ serverId: UUID) async -> [RecordingSpace]
    private let loadPages: (_ serverId: UUID, _ spaceId: String, _ parentPageId: String?) async -> [RecordingPageNode]
    private let onConfirm: (_ serverId: UUID, _ spaceId: String, _ spaceName: String, _ parentPageId: String?, _ parentTitle: String?) -> Void
    private let onCancel: () -> Void

    // UI
    private let outlineView = NSOutlineView()
    private let confirmButton = NSButton(title: "Save", target: nil, action: nil)

    // The top-level server rows; one per configured server.
    private let rootServers: [Node]

    // Exactly-once guard for confirm/cancel/finish.
    private var didFinish = false

    init(servers: [Server],
         initialServerId: UUID?,
         initialSpaceId: String?,
         initialParentPageId: String?,
         bridgeReady: @escaping (_ serverId: UUID) async -> Bool,
         loadSpaces: @escaping (_ serverId: UUID) async -> [RecordingSpace],
         loadPages: @escaping (_ serverId: UUID, _ spaceId: String, _ parentPageId: String?) async -> [RecordingPageNode],
         onConfirm: @escaping (_ serverId: UUID, _ spaceId: String, _ spaceName: String, _ parentPageId: String?, _ parentTitle: String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialServerId = initialServerId
        self.initialSpaceId = initialSpaceId
        self.initialParentPageId = initialParentPageId
        self.bridgeReady = bridgeReady
        self.loadSpaces = loadSpaces
        self.loadPages = loadPages
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        // One server node per configured server forms the static root list.
        self.rootServers = servers.map { Node.server(id: $0.id, name: $0.name) }

        // Fixed-size, non-closable window: there is no untracked close path, so the only
        // ways out are the Cancel/Save buttons (both routed through `finish()`).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording Destination"

        super.init(window: window)

        buildUI()
        preselectInitialDestination()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let destinationLabel = makeLabel("Destination:")

        // Unified destination tree.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.title = "Destination"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autosaveExpandedItems = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = outlineView

        // Buttons.
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelButtonClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        confirmButton.target = self
        confirmButton.action = #selector(confirmButtonClicked)
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r" // Return
        // Disabled until the user selects a space/page node.
        confirmButton.isEnabled = false

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            destinationLabel, scrollView,
            buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Child production

    // Single async source of truth for a node's children, mapping each kind onto the
    // appropriate data closure. Runs off the main actor's critical section but its result
    // is always applied on the main actor by the callers.
    private func produceChildren(for node: Node) async -> [Node] {
        switch node.kind {
        case .server:
            guard let sid = node.serverId, let sname = node.serverName else { return [] }
            // A server whose tab is not open cannot serve spaces yet.
            guard await bridgeReady(sid) else { return [ .info("Open this server's tab to load spaces") ] }
            let spaces = await loadSpaces(sid)
            guard !spaces.isEmpty else { return [ .info("No spaces available") ] }
            return spaces.map { .space(serverId: sid, serverName: sname, id: $0.id, name: $0.name) }
        case .space, .page:
            guard let sid = node.serverId, let sname = node.serverName,
                  let spaceId = node.spaceId, let spaceName = node.spaceName else { return [] }
            let parentId = (node.kind == .page) ? node.pageId : nil
            let pages = await loadPages(sid, spaceId, parentId)
            return pages.map { .page(serverId: sid, serverName: sname, spaceId: spaceId, spaceName: spaceName,
                                     id: $0.id, title: $0.title, hasChildren: $0.hasChildren) }
        case .info:
            return []
        }
    }

    // Lazy-loads a node's children once, on the main actor, then re-expands containers.
    private func loadChildren(for node: Node) {
        guard node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        outlineView.reloadItem(node, reloadChildren: false)   // show "(loading…)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kids = await self.produceChildren(for: node)
            node.children = kids
            node.isLoading = false
            // A space with zero pages is still a valid root destination — just drop its
            // disclosure triangle. Servers always yield at least one child (spaces or info).
            if kids.isEmpty { node.hasChildren = false }
            self.outlineView.reloadItem(node, reloadChildren: true)
            if node.kind == .server || node.kind == .space { self.outlineView.expandItem(node) }
        }
    }

    // Synchronous-await variant used by preselection so children exist before expanding.
    @MainActor
    private func ensureChildrenLoaded(_ node: Node) async {
        guard node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        let kids = await produceChildren(for: node)
        node.children = kids
        node.isLoading = false
        if kids.isEmpty { node.hasChildren = false }
        outlineView.reloadItem(node, reloadChildren: true)
    }

    // MARK: - Preselection

    // Best-effort restoration of the saved destination, one level deeper than before:
    // server → space → (optional) direct-child parent page. Deeply-nested saved parents
    // that are not direct children of the space are NOT auto-selected — acceptable, in the
    // same best-effort spirit as the rest of the chooser.
    private func preselectInitialDestination() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let serverNode = self.rootServers.first(where: { $0.serverId == self.initialServerId }) else { return }

            // Populate children BEFORE expanding so the expand handler skips a duplicate fetch.
            await self.ensureChildrenLoaded(serverNode)
            self.outlineView.expandItem(serverNode)

            guard let spaceId = self.initialSpaceId,
                  let spaceNode = serverNode.children?.first(where: { $0.kind == .space && $0.spaceId == spaceId }) else {
                return  // leave the server expanded; nothing more to select
            }

            await self.ensureChildrenLoaded(spaceNode)
            self.outlineView.expandItem(spaceNode)

            // Prefer the saved parent page if it is a direct child; else select the space root.
            if let parentPageId = self.initialParentPageId,
               let pageNode = spaceNode.children?.first(where: { $0.kind == .page && $0.pageId == parentPageId }) {
                self.select(pageNode)
            } else {
                self.select(spaceNode)
            }
        }
    }

    // Selects a node's row if it is currently visible in the outline.
    private func select(_ node: Node) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - Actions

    @objc private func confirmButtonClicked() { confirm() }
    @objc private func cancelButtonClicked() { cancel() }

    private func confirm() {
        guard !didFinish else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node, node.isSelectable,
              let serverId = node.serverId, let spaceId = node.spaceId, let spaceName = node.spaceName else {
            return   // nothing valid selected (Save is disabled anyway)
        }
        let parentPageId = (node.kind == .page) ? node.pageId : nil
        let parentTitle  = (node.kind == .page) ? node.title  : nil
        onConfirm(serverId, spaceId, spaceName, parentPageId, parentTitle)
        finish()
    }

    private func cancel() {
        guard !didFinish else { return }
        onCancel()
        finish()
    }

    // Ends the sheet exactly once. The window is `.titled` without `.closable`, so the
    // only ways out are the Cancel/Save buttons, both of which route through here; the
    // `didFinish` guard makes a second call a no-op.
    private func finish() {
        didFinish = true
        if let window = window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension RecordingDestinationChooser: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootServers.count
        }
        return (item as? Node)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootServers[index]
        }
        // SAFE: numberOfChildrenOfItem gates this to a populated children array.
        let node = item as! Node
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        switch node.kind {
        case .server: return true
        case .space:  return node.hasChildren
        case .page:   return node.hasChildren
        case .info:   return false
        }
    }
}

// MARK: - NSOutlineViewDelegate

extension RecordingDestinationChooser: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     objectValueFor tableColumn: NSTableColumn?,
                     byItem item: Any?) -> Any? {
        guard let node = item as? Node else { return nil }
        return node.isLoading ? "\(node.title) (loading…)" : node.title
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
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
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.isLoading ? "\(node.title) (loading…)" : node.title
        // Render informational rows in a muted color so they read as non-actionable.
        cell.textField?.textColor = (node.kind == .info) ? .secondaryLabelColor : .labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return (item as? Node)?.isSelectable ?? false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        confirmButton.isEnabled = outlineView.selectedRow >= 0
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        // Lazy-load this node's children exactly once (guarded inside loadChildren).
        loadChildren(for: node)
    }
}
