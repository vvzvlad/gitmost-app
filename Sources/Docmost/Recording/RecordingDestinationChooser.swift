import AppKit
import DocmostCore

// A modal sheet that lets the user configure the recording destination in Settings:
// a target space and an optional parent page (via a lazily-loaded outline tree).
// Programmatic AppKit (no nibs). It only chooses where future recordings land — every
// finished recording then creates a NEW "Recording <timestamp>" child page there.
//
// Lifecycle: the Settings window holds a strong reference while the sheet is up and
// clears it on confirm/cancel/teardown. Confirm and cancel each fire EXACTLY ONCE,
// guarded by the private `didFinish` flag.
final class RecordingDestinationChooser: NSWindowController {

    // A node in the destination outline. Reference type so the outline view can hold and
    // mutate the same instances across reloads (lazy children, loading state).
    private final class OutlineNode {
        // nil id == the synthetic "(Space root)" row, mapping to parentPageId == nil.
        let id: String?
        let title: String
        var hasChildren: Bool
        var children: [OutlineNode]?
        var isLoading: Bool

        init(id: String?, title: String, hasChildren: Bool) {
            self.id = id
            self.title = title
            self.hasChildren = hasChildren
            self.children = nil
            self.isLoading = false
        }
    }

    private let spaces: [RecordingSpace]
    private let initialSpaceId: String?
    private let initialParentPageId: String?
    private let loadChildren: (_ spaceId: String, _ parentPageId: String?) async -> [RecordingPageNode]
    private let onConfirm: (_ spaceId: String, _ spaceName: String, _ parentPageId: String?, _ parentTitle: String?) -> Void
    private let onCancel: () -> Void

    // UI
    private let spacePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outlineView = NSOutlineView()

    // The synthetic root row; always the default selection (parentPageId == nil).
    private var rootNode = OutlineNode(id: nil, title: "(Space root)", hasChildren: true)

    // Bumped on every space switch so stale async child loads can be dropped.
    private var loadGeneration = 0

    // Exactly-once guard for confirm/cancel/finish.
    private var didFinish = false

    init(spaces: [RecordingSpace], initialSpaceId: String?, initialParentPageId: String?,
         loadChildren: @escaping (_ spaceId: String, _ parentPageId: String?) async -> [RecordingPageNode],
         onConfirm: @escaping (_ spaceId: String, _ spaceName: String, _ parentPageId: String?, _ parentTitle: String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.spaces = spaces
        self.initialSpaceId = initialSpaceId
        self.initialParentPageId = initialParentPageId
        self.loadChildren = loadChildren
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        // Fixed-size, non-closable window: there is no untracked close path, so the only
        // ways out are the Cancel/Save buttons (both routed through `finish()`).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording Destination"

        super.init(window: window)

        buildUI()
        // Preselect the configured space when it is still present; else the first space.
        if let initialSpaceId, let index = spaces.firstIndex(where: { $0.id == initialSpaceId }) {
            spacePopUp.selectItem(at: index)
        }
        // Load the selected space's root tree (will best-effort select the saved parent).
        reloadTree(rootReload: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Space picker.
        spacePopUp.translatesAutoresizingMaskIntoConstraints = false
        for space in spaces { spacePopUp.addItem(withTitle: space.name) }
        if !spaces.isEmpty { spacePopUp.selectItem(at: 0) }
        spacePopUp.target = self
        spacePopUp.action = #selector(spaceChanged)

        let spaceLabel = makeLabel("Space:")
        let parentLabel = makeLabel("Parent page:")

        // Parent outline tree.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.title = "Pages"
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
        let confirmButton = NSButton(title: "Save", target: self, action: #selector(confirmButtonClicked))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r" // Return

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            spaceLabel, spacePopUp,
            parentLabel, scrollView,
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

            spacePopUp.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private var selectedSpaceId: String? {
        let index = spacePopUp.indexOfSelectedItem
        guard index >= 0, index < spaces.count else { return nil }
        return spaces[index].id
    }

    private var selectedSpaceName: String? {
        let index = spacePopUp.indexOfSelectedItem
        guard index >= 0, index < spaces.count else { return nil }
        return spaces[index].name
    }

    // MARK: - Tree loading

    @objc private func spaceChanged() {
        reloadTree(rootReload: true)
    }

    // Rebuilds the outline for the currently-selected space. `rootReload` resets the
    // synthetic root node and loads its direct children.
    private func reloadTree(rootReload: Bool) {
        guard let spaceId = selectedSpaceId else { return }
        loadGeneration += 1
        let generation = loadGeneration

        if rootReload {
            rootNode = OutlineNode(id: nil, title: "(Space root)", hasChildren: true)
        }
        let node = rootNode
        node.isLoading = true
        node.children = nil
        outlineView.reloadData()
        // Keep the synthetic root expanded so the user sees the space's pages immediately.
        outlineView.expandItem(node)
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        loadChildrenAsync(for: node, spaceId: spaceId, parentId: nil, generation: generation)
    }

    // Loads children for a node ONCE; stale results (older generation) are dropped.
    private func loadChildrenAsync(for node: OutlineNode, spaceId: String,
                                   parentId: String?, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let nodes = await self.loadChildren(spaceId, parentId)
            // Drop results from a superseded space switch.
            guard generation == self.loadGeneration else { return }
            node.children = nodes.map { OutlineNode(id: $0.id, title: $0.title, hasChildren: $0.hasChildren) }
            node.isLoading = false
            // No expandable disclosure triangle for a node that turned out to be empty.
            if node.children?.isEmpty == true {
                node.hasChildren = false
            }
            self.outlineView.reloadItem(node, reloadChildren: true)
            if node === self.rootNode {
                self.outlineView.expandItem(node)
                // Best-effort preselection of the saved parent if it appears at this level.
                self.preselectInitialParentIfPossible(in: node)
            }
        }
    }

    // If the saved parent page is among the root's direct children, select it. Deep
    // (nested) preselection is intentionally skipped — this is a best-effort convenience.
    private func preselectInitialParentIfPossible(in node: OutlineNode) {
        guard let parentId = initialParentPageId,
              let match = node.children?.first(where: { $0.id == parentId }) else { return }
        let row = outlineView.row(forItem: match)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Actions

    @objc private func confirmButtonClicked() { confirm() }
    @objc private func cancelButtonClicked() { cancel() }

    private func confirm() {
        guard !didFinish else { return }
        guard let spaceId = selectedSpaceId, let spaceName = selectedSpaceName else { cancel(); return }

        // Resolve the selected parent: synthetic root → nil/nil, a real node → its id + title.
        var parentPageId: String? = nil
        var parentTitle: String? = nil
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode, let id = node.id {
            // A real page node (the synthetic root has id == nil).
            parentPageId = id
            parentTitle = node.title
        }

        onConfirm(spaceId, spaceName, parentPageId, parentTitle)
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
            // The root of the outline holds exactly one synthetic "(Space root)" row.
            return 1
        }
        guard let node = item as? OutlineNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // Top level is the synthetic root node.
            return rootNode
        }
        // SAFE: numberOfChildrenOfItem gates this to a populated children array.
        let node = item as! OutlineNode
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? OutlineNode else { return false }
        return node.hasChildren || (node.children?.isEmpty == false)
    }
}

// MARK: - NSOutlineViewDelegate

extension RecordingDestinationChooser: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     objectValueFor tableColumn: NSTableColumn?,
                     byItem item: Any?) -> Any? {
        guard let node = item as? OutlineNode else { return nil }
        return node.isLoading ? "\(node.title) (loading…)" : node.title
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? OutlineNode else { return nil }
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
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
        // Lazy-load this node's children exactly once.
        guard node.children == nil, !node.isLoading else { return }
        guard let spaceId = selectedSpaceId, let parentId = node.id else { return }
        node.isLoading = true
        outlineView.reloadItem(node, reloadChildren: false)
        loadChildrenAsync(for: node, spaceId: spaceId, parentId: parentId, generation: loadGeneration)
    }
}
