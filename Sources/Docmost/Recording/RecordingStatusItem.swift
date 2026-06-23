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
    private let pauseResumeItem = NSMenuItem()
    private let showPanelItem = NSMenuItem()

    // Tooltip ticker; runs ONLY while recording/paused and is invalidated when idle. It only
    // refreshes the tooltip (the visible button is icon-only), so it never causes layout churn.
    private var updateTimer: Timer?

    // Wired by AppDelegate to show the floating recorder panel.
    var onShowPanel: (() -> Void)?

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

        pauseResumeItem.title = "Pause"
        pauseResumeItem.action = #selector(pauseResumeClicked)
        pauseResumeItem.target = self
        menu.addItem(pauseResumeItem)

        menu.addItem(.separator())

        showPanelItem.title = "Show Recorder Panel"
        showPanelItem.action = #selector(showPanelClicked)
        showPanelItem.target = self
        menu.addItem(showPanelItem)
    }

    // Refresh menu titles/enabled right before the menu opens so they are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = RecordingController.shared
        // "Show Recorder Panel" is always available (auto-enable is off, so set it explicitly).
        showPanelItem.isEnabled = true
        switch controller.state {
        case .idle:
            startStopItem.title = "Start Recording"
            startStopItem.isEnabled = controller.canStart
            pauseResumeItem.title = "Pause"
            pauseResumeItem.isEnabled = false
        case .recording:
            startStopItem.title = "Stop Recording"
            startStopItem.isEnabled = true
            pauseResumeItem.title = "Pause"
            pauseResumeItem.isEnabled = true
        case .paused:
            startStopItem.title = "Stop Recording"
            startStopItem.isEnabled = true
            pauseResumeItem.title = "Resume"
            pauseResumeItem.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func startStopClicked() {
        RecordingController.shared.toggle()
    }

    @objc private func pauseResumeClicked() {
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

    @objc private func showPanelClicked() {
        onShowPanel?()
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

        let symbolName: String
        switch controller.state {
        case .idle:
            symbolName = "waveform"
            button.contentTintColor = nil
        case .recording:
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
        switch controller.state {
        case .idle:
            button.toolTip = "Recorder — idle"
        case .recording:
            button.toolTip = "Recording — " + Self.format(controller.elapsedTime)
        case .paused:
            button.toolTip = "Paused — " + Self.format(controller.elapsedTime)
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
