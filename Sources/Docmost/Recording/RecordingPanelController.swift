import AppKit
import QuartzCore

// A small floating, always-on-top recorder popup that drives RecordingController.shared.
// It is one of three UI surfaces (menu, this panel, menu-bar item) over the single shared
// controller, so it only reads `phase` and forwards button taps — it never owns the state.
//
// Modeled faithfully on AFFiNE's meeting-recording popup: the popup is SESSION-SCOPED. It
// appears only while there is an active session (recording → saving → done/failed) and hides
// itself the moment the phase returns to .idle. There is NO persistent idle "Start Recording"
// affordance, NO elapsed timer, NO waveform/level meter, and NO pause button in the popup
// (pause/resume stay available via the menu-bar menu and the File menu).
//
// Layout is minimal — `[ app icon ] [ status text ] [ trailing control ]` — inside a dark,
// rounded translucent HUD card pinned to the bottom-right corner of the active screen. The
// whole bar is draggable.
//
// The window is a borderless non-activating panel: it stays in front of the main window and
// remains visible when the main window is minimized, but it never steals focus from the
// web view. Everything here runs on the main thread.
final class RecordingPanelController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?

    // True once the panel has been positioned in its corner. The first show() snaps the
    // panel to the bottom-right corner; afterwards the user is free to drag it (we do not
    // force-reposition on every show).
    private var didPositionPanel = false

    // MARK: - Visual constants

    private enum Layout {
        static let panelWidth: CGFloat = 220
        static let panelHeight: CGFloat = 52
        static let cornerRadius: CGFloat = 16
        static let screenMargin: CGFloat = 24
        static let contentInsetX: CGFloat = 14
        static let contentInsetY: CGFloat = 8
        static let rowSpacing: CGFloat = 10
        static let appIconSize: CGFloat = 18
        static let statusDotSize: CGFloat = 8
        static let stopButtonHeight: CGFloat = 26
        static let spinnerSize: CGFloat = 18
    }

    // MARK: - Subviews

    // The app icon at the leading edge (AFFiNE shows its app glyph here).
    private let appIconView = NSImageView()
    // A small white recording dot (~8px) shown only while recording/paused.
    private let statusDot = StatusDotView()
    // The single status line ("Recording", "Saving…", "Recording saved", "Recording failed").
    private let statusLabel = NSTextField(labelWithString: "")
    // Trailing red "Stop" button (recording/paused) — a real labeled, layer-backed control so
    // it renders genuinely red with a white title (never a black/dark tinted symbol).
    private let stopButton = FilledButton()
    // Trailing "Dismiss" button shown in the failed phase.
    private let dismissButton = NSButton()
    // Trailing spinner shown while saving.
    private let savingSpinner = NSProgressIndicator()

    // The horizontal content row: [ appIcon ] [ statusDot ] [ statusLabel ] [ trailing control ].
    private let contentRow = NSStackView()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(recordingStateDidChange),
                                               name: .recordingStateDidChange,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Do not touch CALayer/NSView state here: deinit is not guaranteed to run on the main
        // thread, and AppKit/CoreAnimation work must be on main. Pulse teardown already happens
        // on state transitions and in hide(), and the views are destroyed with the controller.
    }

    // MARK: - Public API

    // Order the panel front, creating it lazily on first use. The panel is only ever shown
    // while a session is active; an idle phase routes refreshUI() to hide().
    func show() {
        let panel = panelLazily()
        // Reflect the current phase before showing.
        refreshUI()
        // If the current phase is idle, refreshUI() already hid the panel; don't re-show it.
        guard RecordingController.shared.phase != .idle else { return }
        // Snap to the bottom-right corner on the first show only; respect any later drag.
        if !didPositionPanel {
            positionInCorner(panel)
            didPositionPanel = true
        }
        // orderFrontRegardless keeps the panel visible without activating the app, so the
        // web view keeps keyboard focus.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        // Stop the dot's pulse and the spinner so no animation runs while hidden.
        statusDot.stopPulse()
        savingSpinner.stopAnimation(nil)
    }

    // Toggle visibility (used by the app/menu-bar surfaces).
    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - NSWindowDelegate

    // Closing the panel does not route through hide(); tear down animations here too.
    func windowWillClose(_ notification: Notification) {
        statusDot.stopPulse()
        savingSpinner.stopAnimation(nil)
    }

    // MARK: - Panel construction

    private func panelLazily() -> NSPanel {
        if let panel = panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Draggable anywhere on its translucent body, like a HUD.
        panel.isMovableByWindowBackground = true
        // Transparent host so only the rounded card shows.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Force a dark appearance so the HUD card reads as dark regardless of system theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        panel.contentView = makeContentView()

        self.panel = panel
        return panel
    }

    // Place the panel at the bottom-right of the active screen with a fixed margin.
    private func positionInCorner(_ panel: NSPanel) {
        // Prefer the main screen; fall back to the screen under the mouse.
        let screen = NSScreen.main
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let x = visible.maxX - Layout.panelWidth - Layout.screenMargin
        let y = visible.minY + Layout.screenMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makeContentView() -> NSView {
        // The rounded translucent dark card.
        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.appearance = NSAppearance(named: .darkAqua)
        card.wantsLayer = true
        card.layer?.cornerRadius = Layout.cornerRadius
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        // Pin the card to the intended panel width so its size is deterministic.
        card.widthAnchor.constraint(equalToConstant: Layout.panelWidth).isActive = true

        buildContentRow()

        card.addSubview(contentRow)
        NSLayoutConstraint.activate([
            contentRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.contentInsetX),
            contentRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.contentInsetX),
            contentRow.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.contentInsetY),
            contentRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.contentInsetY)
        ])

        let container = NSView()
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    // Builds the single content row: [ appIcon ] [ statusDot ] [ statusLabel ] [ trailing ].
    private func buildContentRow() {
        // App icon (AFFiNE shows its app glyph at the leading edge).
        appIconView.image = NSApp.applicationIconImage
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.widthAnchor.constraint(equalToConstant: Layout.appIconSize).isActive = true
        appIconView.heightAnchor.constraint(equalToConstant: Layout.appIconSize).isActive = true
        appIconView.setContentHuggingPriority(.required, for: .horizontal)

        // White recording dot.
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: Layout.statusDotSize).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: Layout.statusDotSize).isActive = true
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        // Status label fills the middle and truncates with an ellipsis if needed.
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Red filled "Stop" button — layer-backed, explicit red background, white title.
        configureStopButton()
        // Plain "Dismiss" button for the failed phase.
        configureDismissButton()
        // Saving spinner.
        savingSpinner.style = .spinning
        savingSpinner.controlSize = .small
        savingSpinner.isIndeterminate = true
        savingSpinner.isDisplayedWhenStopped = false
        savingSpinner.translatesAutoresizingMaskIntoConstraints = false
        savingSpinner.widthAnchor.constraint(equalToConstant: Layout.spinnerSize).isActive = true
        savingSpinner.heightAnchor.constraint(equalToConstant: Layout.spinnerSize).isActive = true
        savingSpinner.setContentHuggingPriority(.required, for: .horizontal)

        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.spacing = Layout.rowSpacing
        contentRow.distribution = .fill
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        // All trailing controls live in the row; visibility decides which one is shown.
        contentRow.setViews([appIconView, statusDot, statusLabel, savingSpinner, dismissButton, stopButton],
                            in: .leading)
    }

    // Builds the red filled Stop button. It is a real labeled, layer-backed NSButton with an
    // explicit red layer background and a white attributed title — NOT a borderless tinted SF
    // Symbol, which previously rendered black. See FilledButton below.
    private func configureStopButton() {
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.configure(title: "Stop",
                             titleColor: .white,
                             backgroundColor: .systemRed,
                             cornerRadius: 6)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.setAccessibilityLabel("Stop recording")
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.heightAnchor.constraint(equalToConstant: Layout.stopButtonHeight).isActive = true
    }

    // A plain rounded "Dismiss" button (text only) for the failed phase.
    private func configureDismissButton() {
        dismissButton.title = "Dismiss"
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .small
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.setAccessibilityLabel("Dismiss")
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - Actions

    @objc private func stopClicked() {
        // Stops a recording or a paused recording (toggle() is a no-op in other phases).
        RecordingController.shared.toggle()
    }

    @objc private func dismissClicked() {
        // Cancel the controller's pending auto-dismiss timer and return to idle now; the
        // panel then hides on the resulting state-change notification.
        RecordingController.shared.dismiss()
        // If the controller did not flip to idle (defensive), hide the panel anyway.
        if RecordingController.shared.phase == .idle {
            hide()
        }
    }

    // MARK: - State updates

    @objc private func recordingStateDidChange() {
        // Notifications from RecordingController are posted on the main thread.
        refreshUI()
    }

    // Reflect the controller's phase in the row content, and show/hide the panel: the popup is
    // session-scoped, so any idle phase hides it entirely.
    private func refreshUI() {
        let phase = RecordingController.shared.phase

        switch phase {
        case .idle:
            // Session ended: the popup disappears.
            hide()
            return

        case .recording:
            statusDot.isHidden = false
            statusDot.startPulse()
            statusLabel.stringValue = "Recording"
            showTrailing(.stop)

        case .paused:
            statusDot.isHidden = false
            // Steady (no pulse) while paused; the panel still offers Stop.
            statusDot.setSteady()
            statusLabel.stringValue = "Paused"
            showTrailing(.stop)

        case .saving:
            statusDot.isHidden = true
            statusDot.stopPulse()
            statusLabel.stringValue = "Saving…"
            showTrailing(.spinner)

        case .done:
            statusDot.isHidden = true
            statusDot.stopPulse()
            statusLabel.stringValue = "Recording saved"
            showTrailing(.none)

        case .failed:
            statusDot.isHidden = true
            statusDot.stopPulse()
            statusLabel.stringValue = "Recording failed"
            showTrailing(.dismiss)
        }
    }

    // Which trailing control is visible for the current phase.
    private enum Trailing {
        case stop, spinner, dismiss, none
    }

    private func showTrailing(_ trailing: Trailing) {
        stopButton.isHidden = trailing != .stop
        dismissButton.isHidden = trailing != .dismiss
        savingSpinner.isHidden = trailing != .spinner
        if trailing == .spinner {
            savingSpinner.startAnimation(nil)
        } else {
            savingSpinner.stopAnimation(nil)
        }
    }
}

// MARK: - StatusDotView

// A tiny round WHITE dot backed by a CALayer. It can pulse (opacity 1.0 -> 0.3, autoreversing)
// for the active-recording state, or sit steady for the paused state.
private final class StatusDotView: NSView {

    private let dot = CALayer()
    private static let pulseKey = "statusDotPulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        dot.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(dot)
    }

    override func layout() {
        super.layout()
        // Keep the dot centered and perfectly round regardless of the host size.
        let side = min(bounds.width, bounds.height)
        let origin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        dot.cornerRadius = side / 2
        CATransaction.commit()
    }

    // Steady white (no pulse), used while paused.
    func setSteady() {
        stopPulse()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = NSColor.white.cgColor
        dot.opacity = 1.0
        CATransaction.commit()
    }

    // Start the gentle white pulse. Idempotent: re-adding replaces it.
    func startPulse() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = NSColor.white.cgColor
        dot.opacity = 1.0
        CATransaction.commit()

        dot.removeAnimation(forKey: Self.pulseKey)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: Self.pulseKey)
    }

    // Remove the pulse so no CAAnimation dangles when not recording.
    func stopPulse() {
        dot.removeAnimation(forKey: Self.pulseKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.opacity = 1.0
        CATransaction.commit()
    }
}

// MARK: - FilledButton

// A layer-backed, borderless NSButton that paints an explicit solid background color behind a
// white attributed title. Used for AFFiNE's filled red "Stop" button. This deliberately avoids
// a tinted SF Symbol (which rendered as a black/dark glyph): the background is a real CALayer
// fill and the title is an attributed string, so the control is unmistakably red with white
// text in any system appearance.
private final class FilledButton: NSButton {

    private var fillColor: NSColor = .systemRed

    func configure(title: String, titleColor: NSColor, backgroundColor: NSColor, cornerRadius: CGFloat) {
        self.fillColor = backgroundColor
        isBordered = false
        // .regularSquare leaves drawing entirely to us (no system bezel that could tint).
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = backgroundColor.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: titleColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .paragraphStyle: paragraph
        ])
        // Give the label some horizontal breathing room beyond its intrinsic text width.
        contentEdgeInsetsPadded = true
    }

    // Re-assert the fill after appearance changes so it never falls back to a system bezel color.
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = fillColor.cgColor
    }

    // Pad the intrinsic width so the title is not cramped against the rounded edges.
    private var contentEdgeInsetsPadded = false
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if contentEdgeInsetsPadded {
            size.width += 20
        }
        return size
    }
}
