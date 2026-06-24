import AppKit

// A menu-bar (status bar) item driving RecordingController.shared. One of the three UI
// surfaces over the shared controller, it only reflects state and forwards taps. The icon and
// tint track the controller live; the elapsed time lives in the button's tooltip (kept tidy —
// no cramped inline text in the menu bar). Its menu is rebuilt on demand via NSMenuDelegate so
// titles/enabled are always current. Main thread only.
final class RecordingStatusItem: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let startStopItem = NSMenuItem()

    // Tooltip ticker; runs ONLY while recording/paused and is invalidated when idle. It only
    // refreshes the tooltip (the visible button is icon-only), so it never causes layout churn.
    private var updateTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu

        // Icon-only button; the elapsed time goes into the tooltip, never the title.
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
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

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        // Disable AppKit's automatic item enabling: otherwise it re-enables any item whose
        // target responds to the action selector, overriding the manual isEnabled state set
        // in menuNeedsUpdate(_:). With this off, that manual state is authoritative.
        menu.autoenablesItems = false

        startStopItem.title = "Start Recording"
        startStopItem.action = #selector(startStopClicked)
        startStopItem.target = self
        menu.addItem(startStopItem)
    }

    // Refresh the start/stop item title/enabled right before the menu opens so it is always
    // current. Reads `phase` (not `state`) so the delivery phases (saving/done/failed) are
    // handled: during them `state` is already .idle but the session isn't over, so "Start
    // Recording" must stay disabled rather than silently no-op via toggle().
    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = RecordingController.shared
        switch controller.phase {
        case .idle:
            startStopItem.title = "Start Recording"
            startStopItem.isEnabled = controller.canStart
        case .recording:
            startStopItem.title = "Stop Recording"
            startStopItem.isEnabled = true
        case .paused:
            startStopItem.title = "Stop Recording"
            startStopItem.isEnabled = true
        case .saving, .done, .failed:
            // A session is finalizing or auto-dismissing: there is nothing to start or stop.
            // Keep the control disabled so it never no-ops.
            startStopItem.title = "Start Recording"
            startStopItem.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func startStopClicked() {
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
            button.contentTintColor = .systemRed
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
