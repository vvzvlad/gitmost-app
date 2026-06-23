import AppKit

// A small floating, always-on-top recorder panel that drives RecordingController.shared.
// It is one of three UI surfaces (menu, this panel, menu-bar item) over the single shared
// controller, so it only reads state and forwards button taps — it never owns the state.
//
// The panel is a non-activating utility window: it stays in front of the main window and
// remains visible when the main window is minimized, but it never steals focus from the
// web view. Everything here runs on the main thread.
final class RecordingPanelController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?

    // Big monospaced mm:ss / h:mm:ss elapsed-time label.
    private let timeLabel = NSTextField(labelWithString: "00:00")
    // Audio peak meter bound to RecordingController.shared.audioLevel.
    private let levelMeter = NSLevelIndicator()
    // Primary action: Start (idle) / Stop (recording or paused).
    private let primaryButton = NSButton()
    // Secondary action: Pause (recording) / Resume (paused); hidden while idle.
    private let secondaryButton = NSButton()

    // ~0.1s ticker that refreshes the time label + meter; only runs while not idle and is
    // invalidated when idle so it never burns CPU in the background.
    private var updateTimer: Timer?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(recordingStateDidChange),
                                               name: .recordingStateDidChange,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        updateTimer?.invalidate()
    }

    // MARK: - Public API

    // Order the panel front, creating it lazily on first use.
    func show() {
        let panel = panelLazily()
        // Reflect button titles/enabled/visibility before showing.
        refreshUI()
        // orderFrontRegardless keeps the panel visible without activating the app, so the
        // web view keeps keyboard focus.
        panel.orderFrontRegardless()
        // Now that the panel is visible, (re)arm the ticker if a recording is active, and
        // refresh the label/meter once so the reopened panel shows current values instead of
        // waiting up to 0.1s for the first tick.
        updateTimerLifecycle()
        updateMeters()
    }

    func hide() {
        panel?.orderOut(nil)
        // The panel is no longer visible, so tear down the ticker even if recording continues.
        updateTimerLifecycle()
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

    // Closing the panel via its close box does not route through hide(), so tear down the
    // ticker here.
    func windowWillClose(_ notification: Notification) {
        // The window is still on screen here (isVisible == true), so calling
        // updateTimerLifecycle() would re-arm the timer during an active recording.
        // The panel is closing, so just tear the ticker down unconditionally.
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Panel construction

    private func panelLazily() -> NSPanel {
        if let panel = panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Recorder"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Fixed-size utility window; not resizable.
        panel.styleMask.remove(.resizable)
        panel.isReleasedWhenClosed = false
        // Observe the close box so the update timer is torn down when the panel is closed
        // while a recording is still active.
        panel.delegate = self

        panel.contentView = makeContentView()
        panel.center()

        self.panel = panel
        return panel
    }

    private func makeContentView() -> NSView {
        // Big monospaced timer.
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        timeLabel.alignment = .center
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        timeLabel.isEditable = false
        timeLabel.isSelectable = false

        // Continuous capacity meter bound to the 0...1 audio level.
        levelMeter.levelIndicatorStyle = .continuousCapacity
        levelMeter.minValue = 0
        levelMeter.maxValue = 1
        levelMeter.doubleValue = 0
        levelMeter.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.heightAnchor.constraint(equalToConstant: 16).isActive = true

        primaryButton.bezelStyle = .rounded
        primaryButton.setButtonType(.momentaryPushIn)
        primaryButton.title = "Start"
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.setButtonType(.momentaryPushIn)
        secondaryButton.title = "Pause"
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)

        let buttonRow = NSStackView(views: [primaryButton, secondaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8

        let stack = NSStackView(views: [timeLabel, levelMeter, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // Make the meter span the panel width.
            levelMeter.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            levelMeter.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16)
        ])
        return container
    }

    // MARK: - Actions

    @objc private func primaryClicked() {
        RecordingController.shared.toggle()
    }

    @objc private func secondaryClicked() {
        let controller = RecordingController.shared
        switch controller.state {
        case .recording:
            controller.pause()
        case .paused:
            controller.resume()
        case .idle:
            break
        }
    }

    // MARK: - State updates

    @objc private func recordingStateDidChange() {
        // Notifications from RecordingController are posted on the main thread.
        refreshUI()
    }

    // Reflect the controller's state in titles/enabled/visibility and (re)arm the ticker.
    private func refreshUI() {
        let controller = RecordingController.shared

        switch controller.state {
        case .idle:
            primaryButton.title = "Start"
            primaryButton.isEnabled = controller.canStart
            secondaryButton.title = "Pause"
            secondaryButton.isHidden = true
        case .recording:
            primaryButton.title = "Stop"
            primaryButton.isEnabled = true
            secondaryButton.title = "Pause"
            secondaryButton.isHidden = false
            secondaryButton.isEnabled = true
        case .paused:
            primaryButton.title = "Stop"
            primaryButton.isEnabled = true
            secondaryButton.title = "Resume"
            secondaryButton.isHidden = false
            secondaryButton.isEnabled = true
        }

        updateMeters()
        updateTimerLifecycle()
    }

    // Refresh the elapsed label and meter from the controller. Cheap; called on every tick.
    private func updateMeters() {
        let controller = RecordingController.shared
        timeLabel.stringValue = Self.format(controller.elapsedTime)
        // audioLevel is already 0 while idle/paused, so this naturally drops the meter.
        levelMeter.doubleValue = Double(controller.audioLevel)
    }

    // Start the ~0.1s ticker only while recording or paused AND the panel is actually
    // visible; tear it down when idle or while hidden so the panel costs nothing in the
    // background. The paused path keeps the label correct even though the meter reads 0 (a
    // 0.1s tick is fine for both).
    private func updateTimerLifecycle() {
        let isActive = RecordingController.shared.state != .idle && (panel?.isVisible == true)
        if isActive {
            guard updateTimer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateMeters()
            }
            RunLoop.main.add(timer, forMode: .common)
            updateTimer = timer
        } else {
            updateTimer?.invalidate()
            updateTimer = nil
        }
    }

    // mm:ss, or h:mm:ss once past an hour.
    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
