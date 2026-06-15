import AppKit
import DocmostCore

// A horizontal strip with a leading Back button, browser-style server tabs (one
// per server) and a trailing settings button.
final class TabBarView: NSView {

    var onSelect: ((UUID) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onGoBack: (() -> Void)?

    private let stackView = NSStackView()
    private let settingsButton = NSButton()
    // Leading "Back" button shown only while an external (non-server) page is open.
    private let backButton = NSButton()
    // Bottom hairline; added before the tabs so the selected tab covers it and
    // appears connected to the content area below.
    private let separator = NSBox()

    // One tab view per server, keyed by server id.
    private var tabsByID: [UUID: TabItemView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // Subtle native bar background.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Bottom separator first => behind the tabs (the selected tab covers it).
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Full-height row so tabs reach the bottom edge and connect to the content.
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 2
        // Hidden arranged subviews are detached from layout, so the hidden back
        // button leaves no leading gap before the tabs.
        stackView.detachesHiddenViews = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Back button: first item in the strip, hidden until an external page opens.
        backButton.title = "Back"
        backButton.image = NSImage(systemSymbolName: "chevron.backward",
                                   accessibilityDescription: "Back")
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .rounded
        backButton.setButtonType(.momentaryPushIn)
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.isHidden = true
        stackView.addArrangedSubview(backButton)

        settingsButton.title = "Servers…"
        settingsButton.bezelStyle = .rounded
        settingsButton.setButtonType(.momentaryPushIn)
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settingsButton)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            settingsButton.leadingAnchor.constraint(greaterThanOrEqualTo: stackView.trailingAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // Rebuild the server tabs and highlight the selected one.
    func reload(servers: [Server], selectedID: UUID?) {
        // Remove existing tab views, keeping the persistent back button.
        for item in tabsByID.values {
            stackView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        tabsByID.removeAll()

        for server in servers {
            let id = server.id
            let item = TabItemView(title: server.name)
            item.onClick = { [weak self] in self?.onSelect?(id) }
            item.setSelected(id == selectedID)
            stackView.addArrangedSubview(item)
            // Tabs span the full bar height so they reach (and cover) the bottom line.
            item.heightAnchor.constraint(equalTo: heightAnchor).isActive = true
            tabsByID[id] = item
        }
    }

    // Keep the layer background in sync with the system appearance; a CGColor
    // captured once is not adaptive, so re-resolve it on appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // Show/hide the leading Back button (used when an external page is displayed).
    func setBackButtonVisible(_ visible: Bool) {
        backButton.isHidden = !visible
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func backClicked() {
        onGoBack?()
    }
}
