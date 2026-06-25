import AppKit

// The second-level strip below the server tabs: it shows the browser-style PAGE tabs of the
// currently selected server, plus a trailing "+" button to open a new tab. Mirrors
// TabBarView's structure and visuals (synced layer background, bottom hairline behind the
// tabs, full-height tab items reaching the content area).
final class PageTabBarView: NSView {

    var onSelect: ((UUID) -> Void)?   // page-tab id
    var onClose: ((UUID) -> Void)?    // page-tab id
    var onNewTab: (() -> Void)?

    private let stackView = NSStackView()
    private let newTabButton = NSButton()
    // Bottom hairline; added before the tabs so the selected tab covers it and appears
    // connected to the content area below.
    private let separator = NSBox()

    // One tab view per page tab, keyed by page-tab id (so updateTitle can patch in place).
    private var tabsByID: [UUID: TabItemView] = [:]
    // The currently displayed tab ids in order, used to skip full rebuilds when unchanged.
    private var currentOrder: [UUID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Subtle native bar background, kept in sync with the system appearance.
        TabStrip.applyBackground(to: self)

        // Bottom separator first => behind the tabs (the selected tab covers it).
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Full-height row so tabs reach the bottom edge and connect to the content.
        TabStrip.configure(stack: stackView)
        addSubview(stackView)

        // Trailing "+" button: always visible, opens a new tab of the current server.
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.imagePosition = .imageOnly
        newTabButton.bezelStyle = .rounded
        newTabButton.setButtonType(.momentaryPushIn)
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            newTabButton.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 4),
            newTabButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // Rebuild the page tabs. `showClose` is false when only one tab remains (hide every ×).
    func reload(tabs: [(id: UUID, title: String)], selectedID: UUID?, showClose: Bool) {
        let newOrder = tabs.map { $0.id }

        // Fast path: the same ids in the same order (and every one already has a view) means the
        // composition is unchanged, so patch the existing items in place. This avoids tearing
        // down and recreating views on every select/new/close (which would reset hover state).
        if newOrder == currentOrder, newOrder.allSatisfy({ tabsByID[$0] != nil }) {
            for tab in tabs {
                guard let item = tabsByID[tab.id] else { continue }
                item.title = tab.title
                item.setSelected(tab.id == selectedID)
                item.showsCloseButton = showClose
            }
            return
        }

        // Full rebuild: the set or order of tabs actually changed.
        TabStrip.clearItems(&tabsByID, from: stackView)

        for tab in tabs {
            let id = tab.id
            let item = TabStrip.makeItem(title: tab.title, selected: id == selectedID,
                                         in: stackView, fullHeightOf: self)
            item.showsCloseButton = showClose
            item.onClick = { [weak self] in self?.onSelect?(id) }
            item.onClose = { [weak self] in self?.onClose?(id) }
            tabsByID[id] = item
        }
        currentOrder = newOrder
    }

    // Update just one tab's title without a full rebuild (called on document.title changes).
    func updateTitle(id: UUID, title: String) {
        tabsByID[id]?.title = title
    }

    // Keep the layer background in sync with the system appearance; a CGColor captured once
    // is not adaptive, so re-resolve it on appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        TabStrip.applyBackground(to: self)
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }
}
