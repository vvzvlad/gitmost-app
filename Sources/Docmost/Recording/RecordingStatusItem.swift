import AppKit

// A menu-bar (status bar) item driving RecordingController.shared. One of the three UI
// surfaces over the shared controller, it only reflects state and forwards taps. The icon and
// tint track the controller live; the elapsed time lives in the button's tooltip (kept tidy —
// no cramped inline text in the menu bar). A left-click toggles recording directly via
// RecordingController.shared.toggle() (idle -> start, recording/paused -> stop); there is no
// dropdown menu. Main thread only.
final class RecordingStatusItem: NSObject {

    private let statusItem: NSStatusItem

    // Tooltip ticker; runs ONLY while recording/paused and is invalidated when idle. It only
    // refreshes the tooltip (the visible button is icon-only), so it never causes layout churn.
    private var updateTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Icon-only button; the elapsed time goes into the tooltip, never the title.
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(recordingStateDidChange),
                                               name: .recordingStateDidChange,
                                               object: nil)

        refreshButton()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        updateTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Click

    // A left-click toggles recording directly (idle -> start, recording/paused -> stop).
    // toggle() no-ops during the saving/done/failed delivery phases, so no extra guard is needed.
    @objc private func statusItemClicked() {
        RecordingController.shared.toggle()
    }

    // MARK: - State updates

    @objc private func recordingStateDidChange() {
        // Posted on the main thread by RecordingController.
        refreshButton()
    }

    // Update the button icon/tint and tooltip and (re)arm the tooltip ticker for the current
    // state. The visible button stays icon-only; the time lives in the tooltip.
    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let controller = RecordingController.shared

        // Drive the icon from `phase` so the active delivery phases (saving/done/failed) read
        // as an in-progress session rather than idle. Saving/done/failed map to the recording
        // icon to keep it simple: any non-idle phase shows an active recorder.
        let symbolName: String
        switch controller.phase {
        case .idle:
            symbolName = "waveform"
            button.contentTintColor = nil
        case .recording, .saving, .done, .failed:
            symbolName = "record.circle.fill"
            // A nil tint lets the SF Symbol render with the system's adaptive template color,
            // which appears as a light/gray glyph on the (dark) menu bar instead of a hard-to-see
            // dark one.
            button.contentTintColor = nil
        case .paused:
            symbolName = "pause.circle.fill"
            button.contentTintColor = .systemOrange
        }
        // Keep the button strictly icon-only — no cramped inline mm:ss text.
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Recorder")
        button.imagePosition = .imageOnly
        button.title = ""

        updateTooltip()
        updateTimerLifecycle()
    }

    // Put the state and elapsed time into the tooltip (e.g. "Recording — 1:23"); idle shows a
    // plain label. Refreshed on the existing 1s ticker while active.
    private func updateTooltip() {
        guard let button = statusItem.button else { return }
        let controller = RecordingController.shared
        switch controller.phase {
        case .idle:
            button.toolTip = "Recorder — idle"
        case .recording:
            button.toolTip = "Recording — " + Self.format(controller.elapsedTime)
        case .paused:
            button.toolTip = "Paused — " + Self.format(controller.elapsedTime)
        case .saving:
            button.toolTip = "Saving…"
        case .done:
            button.toolTip = "Recording saved"
        case .failed:
            button.toolTip = "Recording failed"
        }
    }

    // Run the tooltip ticker ONLY while recording/paused; invalidate it when idle so the
    // status item costs nothing in the background.
    private func updateTimerLifecycle() {
        let isActive = RecordingController.shared.state != .idle
        if isActive {
            guard updateTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateTooltip()
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
