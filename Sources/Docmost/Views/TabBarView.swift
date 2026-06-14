import AppKit
import DocmostCore

// A horizontal strip of tab buttons (one per server) plus a trailing settings button.
final class TabBarView: NSView {

    var onSelect: ((UUID) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onGoBack: (() -> Void)?

    private let stackView = NSStackView()
    private let settingsButton = NSButton()
    // Leading "Back" button shown only while an external (non-server) page is open.
    private let backButton = NSButton()

    // Maps a tab button back to its server id.
    private var buttonsByID: [UUID: NSButton] = [:]

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

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        // Hidden arranged subviews are detached from layout, so the hidden back
        // button leaves no leading gap before the server tabs.
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

        // Bottom separator line for a clean native look.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            settingsButton.leadingAnchor.constraint(greaterThanOrEqualTo: stackView.trailingAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // Rebuild the tab buttons for the given servers and highlight the selected one.
    func reload(servers: [Server], selectedID: UUID?) {
        // Remove existing per-server tab buttons, keeping the persistent back button.
        for button in buttonsByID.values {
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttonsByID.removeAll()

        for server in servers {
            let button = NSButton()
            button.title = server.name
            button.bezelStyle = .rounded
            // A toggle push button gives a clear on/off visual for the active tab.
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(server.id.uuidString)
            button.state = (server.id == selectedID) ? .on : .off
            stackView.addArrangedSubview(button)
            buttonsByID[server.id] = button
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        // Keep the visual selection consistent immediately.
        for (buttonID, button) in buttonsByID {
            button.state = (buttonID == id) ? .on : .off
        }
        onSelect?(id)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    // Show/hide the leading Back button (used when an external page is displayed).
    func setBackButtonVisible(_ visible: Bool) {
        backButton.isHidden = !visible
    }

    @objc private func backClicked() {
        onGoBack?()
    }
}
