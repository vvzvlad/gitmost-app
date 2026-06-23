import AppKit
import QuartzCore

// A small floating, always-on-top recorder HUD that drives RecordingController.shared.
// It is one of three UI surfaces (menu, this panel, menu-bar item) over the single shared
// controller, so it only reads state and forwards button taps — it never owns the state.
//
// Visually it is a dark, rounded "pill" pinned to the bottom-right corner of the active
// screen (modeled on AFFiNE's meeting-recording popup): a translucent HUD card holding a
// pulsing record dot, a monospaced elapsed-time label, a live audio level meter, and small
// circular Pause/Resume + Stop icon buttons. When idle it collapses to a single
// "Start Recording" affordance.
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
        static let panelWidth: CGFloat = 280
        static let panelHeight: CGFloat = 64
        static let cornerRadius: CGFloat = 16
        static let screenMargin: CGFloat = 24
        static let contentInsetX: CGFloat = 14
        static let contentInsetY: CGFloat = 8
        static let stackSpacing: CGFloat = 10
        static let iconButtonSize: CGFloat = 28
        static let recordDotSize: CGFloat = 10
    }

    // MARK: - Subviews

    // Pulsing record dot (red while recording, steady amber while paused).
    private let recordDot = RecordDotView()
    // Big monospaced m:ss / h:mm:ss elapsed-time label.
    private let timeLabel = NSTextField(labelWithString: "0:00")
    // Live waveform-style audio meter bound to RecordingController.shared.audioLevel.
    private let levelMeter = LevelMeterView()
    // Pause (recording) / Resume (paused).
    private let pauseButton = NSButton()
    // Stop (recording or paused).
    private let stopButton = NSButton()

    // Idle affordance: a red dot + "Start Recording" label, plus a muted hint shown when a
    // recording cannot be started right now.
    private let idleDot = RecordDotView()
    private let idleLabel = NSTextField(labelWithString: "Start Recording")
    private let idleHintLabel = NSTextField(labelWithString: "Open a page to record")
    // A transparent button covering the whole idle row so the entire pill starts recording.
    private let idleStartButton = NSButton()

    // The two row containers; exactly one is visible at a time.
    private let recordingRow = NSStackView()
    private let idleRow = NSStackView()

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
        // Do not touch CALayer/NSView state here: deinit is not guaranteed to run on the main
        // thread, and AppKit/CoreAnimation work must be on main. Pulse teardown already happens
        // on state transitions and in hide(), and the views are destroyed with the controller.
    }

    // MARK: - Public API

    // Order the panel front, creating it lazily on first use.
    func show() {
        let panel = panelLazily()
        // Reflect button titles/enabled/visibility before showing.
        refreshUI()
        // Snap to the bottom-right corner on the first show only; respect any later drag.
        if !didPositionPanel {
            positionInCorner(panel)
            didPositionPanel = true
        }
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
        // Stop both dots' pulse so no infinite CAAnimation runs while the panel is hidden.
        // show() calls refreshUI(), which re-arms startPulse during an active recording.
        recordDot.stopPulse()
        idleDot.stopPulse()
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

    // Closing the panel does not route through hide(), so tear down the ticker here.
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
        // Observe close so the update timer is torn down when the panel is closed while a
        // recording is still active.
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
        // Pin the card to the intended panel width so its size is deterministic regardless of
        // which row (idle or recording) is shown, avoiding Auto Layout width ambiguity.
        card.widthAnchor.constraint(equalToConstant: Layout.panelWidth).isActive = true

        buildRecordingRow()
        buildIdleRow()

        // Both rows fill the same inset area; visibility decides which one is seen.
        card.addSubview(recordingRow)
        card.addSubview(idleRow)
        NSLayoutConstraint.activate([
            recordingRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.contentInsetX),
            recordingRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.contentInsetX),
            recordingRow.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.contentInsetY),
            recordingRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.contentInsetY),

            idleRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.contentInsetX),
            idleRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.contentInsetX),
            idleRow.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.contentInsetY),
            idleRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.contentInsetY)
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

    // RECORDING / PAUSED row: dot · time · meter · pause · stop.
    private func buildRecordingRow() {
        recordDot.translatesAutoresizingMaskIntoConstraints = false
        recordDot.widthAnchor.constraint(equalToConstant: Layout.recordDotSize).isActive = true
        recordDot.heightAnchor.constraint(equalToConstant: Layout.recordDotSize).isActive = true
        recordDot.setContentHuggingPriority(.required, for: .horizontal)

        configureLabel(timeLabel,
                       font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                       color: .white)
        timeLabel.alignment = .left
        timeLabel.stringValue = "0:00"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        levelMeter.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.heightAnchor.constraint(equalToConstant: 22).isActive = true
        // The meter expands to fill the middle.
        levelMeter.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureIconButton(pauseButton,
                            symbol: "pause.fill",
                            tint: .white,
                            accessibility: "Pause recording",
                            action: #selector(pauseClicked))
        configureIconButton(stopButton,
                            symbol: "stop.fill",
                            tint: .systemRed,
                            accessibility: "Stop recording",
                            action: #selector(stopClicked))

        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = Layout.stackSpacing
        recordingRow.distribution = .fill
        recordingRow.translatesAutoresizingMaskIntoConstraints = false
        recordingRow.setViews([recordDot, timeLabel, levelMeter, pauseButton, stopButton], in: .leading)
    }

    // IDLE row: red dot · "Start Recording" / hint, with a full-width transparent start button.
    private func buildIdleRow() {
        idleDot.translatesAutoresizingMaskIntoConstraints = false
        idleDot.widthAnchor.constraint(equalToConstant: Layout.recordDotSize).isActive = true
        idleDot.heightAnchor.constraint(equalToConstant: Layout.recordDotSize).isActive = true
        idleDot.setContentHuggingPriority(.required, for: .horizontal)
        idleDot.setSteadyColor(.systemRed)

        configureLabel(idleLabel,
                       font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                       color: .white)
        idleLabel.alignment = .left

        configureLabel(idleHintLabel,
                       font: NSFont.systemFont(ofSize: 14, weight: .regular),
                       color: NSColor.white.withAlphaComponent(0.5))
        idleHintLabel.alignment = .left
        idleHintLabel.isHidden = true

        // Transparent overlay button: makes the whole idle row a single Start target.
        idleStartButton.title = ""
        idleStartButton.isBordered = false
        idleStartButton.isTransparent = true
        idleStartButton.target = self
        idleStartButton.action = #selector(startClicked)
        idleStartButton.setAccessibilityLabel("Start recording")
        idleStartButton.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView(views: [idleLabel, idleHintLabel])
        labelStack.orientation = .horizontal
        labelStack.alignment = .centerY
        labelStack.spacing = 6

        idleRow.orientation = .horizontal
        idleRow.alignment = .centerY
        idleRow.spacing = Layout.stackSpacing
        idleRow.distribution = .fill
        idleRow.translatesAutoresizingMaskIntoConstraints = false
        idleRow.setViews([idleDot, labelStack], in: .leading)

        // Overlay the transparent start button across the whole idle row.
        idleRow.addSubview(idleStartButton, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            idleStartButton.leadingAnchor.constraint(equalTo: idleRow.leadingAnchor),
            idleStartButton.trailingAnchor.constraint(equalTo: idleRow.trailingAnchor),
            idleStartButton.topAnchor.constraint(equalTo: idleRow.topAnchor),
            idleStartButton.bottomAnchor.constraint(equalTo: idleRow.bottomAnchor)
        ])
    }

    // MARK: - View helpers

    private func configureLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
    }

    // Borderless circular SF Symbol icon button with a content tint.
    private func configureIconButton(_ button: NSButton,
                                     symbol: String,
                                     tint: NSColor,
                                     accessibility: String,
                                     action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.contentTintColor = tint
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Layout.iconButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Layout.iconButtonSize).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Actions

    @objc private func startClicked() {
        RecordingController.shared.toggle()
    }

    @objc private func stopClicked() {
        // Stops a recording or a paused recording.
        RecordingController.shared.toggle()
    }

    @objc private func pauseClicked() {
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

    // Reflect the controller's state in layout/icons/visibility and (re)arm the ticker.
    private func refreshUI() {
        let controller = RecordingController.shared

        switch controller.state {
        case .idle:
            showIdleLayout()
            let canStart = controller.canStart
            idleStartButton.isEnabled = canStart
            idleLabel.isHidden = !canStart
            idleHintLabel.isHidden = canStart
            idleDot.setSteadyColor(canStart ? .systemRed : NSColor.white.withAlphaComponent(0.4))

        case .recording:
            showRecordingLayout()
            recordDot.startPulse(color: .systemRed)
            setPauseButton(symbol: "pause.fill", accessibility: "Pause recording")

        case .paused:
            showRecordingLayout()
            // Steady amber while paused — no pulse.
            recordDot.setSteadyColor(.systemOrange)
            setPauseButton(symbol: "play.fill", accessibility: "Resume recording")
        }

        updateMeters()
        updateTimerLifecycle()
    }

    private func setPauseButton(symbol: String, accessibility: String) {
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        pauseButton.setAccessibilityLabel(accessibility)
    }

    // Swap to the recording/paused row; tear down any idle-dot animation.
    private func showRecordingLayout() {
        idleDot.stopPulse()
        idleRow.isHidden = true
        recordingRow.isHidden = false
    }

    // Swap to the idle row; tear down the record-dot pulse so no CAAnimation dangles.
    private func showIdleLayout() {
        recordDot.stopPulse()
        recordingRow.isHidden = true
        idleRow.isHidden = false
    }

    // Refresh the elapsed label and meter from the controller. Cheap; called on every tick.
    private func updateMeters() {
        let controller = RecordingController.shared
        timeLabel.stringValue = Self.format(controller.elapsedTime)
        // audioLevel is already 0 while idle/paused, so the meter naturally settles.
        levelMeter.update(level: CGFloat(controller.audioLevel))
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

    // m:ss, or h:mm:ss once past an hour.
    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - RecordDotView

// A tiny round dot backed by a CALayer. It can pulse (opacity 1.0 -> 0.3, autoreversing) for
// the active-recording state, or sit steady in a given color for paused / idle states.
private final class RecordDotView: NSView {

    private let dot = CALayer()
    private static let pulseKey = "recordDotPulse"

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
        dot.backgroundColor = NSColor.systemRed.cgColor
        layer?.addSublayer(dot)
    }

    override func layout() {
        super.layout()
        // Keep the dot centered and perfectly round regardless of the host size.
        let side = min(bounds.width, bounds.height)
        let origin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        // Disable implicit animation on layout-driven frame changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        dot.cornerRadius = side / 2
        CATransaction.commit()
    }

    // Set a steady (non-pulsing) color and remove any running pulse.
    func setSteadyColor(_ color: NSColor) {
        stopPulse()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        dot.opacity = 1.0
        CATransaction.commit()
    }

    // Start the pulsing animation in the given color. Idempotent: re-adding replaces it.
    func startPulse(color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
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

// MARK: - LevelMeterView

// A small waveform-style meter: a fixed number of vertical rounded bars whose heights track
// the live audio level. Each bar gets a fixed per-bar weight plus a little index/phase jitter
// so it reads like a waveform rather than a flat block; the heights are lerped toward their
// targets each tick so the meter glides instead of snapping.
private final class LevelMeterView: NSView {

    private static let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let maxBarHeight: CGFloat = 22
    private static let minBarHeight: CGFloat = 3
    // Per-bar weighting so the centre bars read taller than the edges.
    private static let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.8, 0.6]

    private var bars: [CALayer] = []
    // Current (animated) and target normalized heights, one per bar.
    private var current: [CGFloat]
    private var targets: [CGFloat]
    // Advancing phase drives the per-tick jitter so the waveform shimmers slightly.
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        current = Array(repeating: 0, count: LevelMeterView.barCount)
        targets = Array(repeating: 0, count: LevelMeterView.barCount)
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        current = Array(repeating: 0, count: LevelMeterView.barCount)
        targets = Array(repeating: 0, count: LevelMeterView.barCount)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    // The view sizes itself around the fixed bar geometry but is happy to stretch wider; bars
    // stay centered within whatever width Auto Layout hands us.
    override var intrinsicContentSize: NSSize {
        let width = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        return NSSize(width: width, height: Self.maxBarHeight)
    }

    override func layout() {
        super.layout()
        positionBars()
    }

    // Push a new audio level (0...1). We compute each bar's target from the level, its fixed
    // weight, and a phase-based jitter; the actual heights chase the targets in update-driven
    // ticks (here we lerp once per call, which is the 0.1s tick cadence).
    func update(level: CGFloat) {
        let clamped = max(0, min(1, level))
        phase += 0.6
        for i in 0..<Self.barCount {
            let weight = Self.weights[i]
            // A small deterministic shimmer per bar so it doesn't move in lockstep.
            let jitter = 0.12 * (sin(phase + CGFloat(i) * 1.7) * 0.5 + 0.5)
            var target = clamped * weight + (clamped > 0.02 ? jitter : 0)
            target = max(0, min(1, target))
            targets[i] = target
            // Lerp the current value toward the target so the bar glides.
            current[i] += (target - current[i]) * 0.5
        }
        positionBars()
    }

    private func positionBars() {
        let totalWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        let startX = (bounds.width - totalWidth) / 2
        let midY = bounds.height / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let normalized = i < current.count ? current[i] : 0
            let height = max(Self.minBarHeight, normalized * Self.maxBarHeight)
            let x = startX + CGFloat(i) * (Self.barWidth + Self.barGap)
            bar.frame = CGRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
            bar.cornerRadius = Self.barWidth / 2
        }
        CATransaction.commit()
    }
}
