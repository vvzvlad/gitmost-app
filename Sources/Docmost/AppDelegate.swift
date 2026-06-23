import AppKit
import DocmostCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references so the window and the store stay alive for the app lifetime.
    private var windowController: MainWindowController?
    private var store: ServerStore?

    // Stage B recording UI surfaces (the floating panel and the menu-bar item), both
    // driving the same RecordingController.shared as the File menu. Held strongly so they
    // live for the app lifetime.
    private var recordingPanel: RecordingPanelController?
    private var recordingStatusItem: RecordingStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the main menu first so standard Edit actions (copy/paste) work everywhere.
        MenuBuilder.installMainMenu()

        // Shared data store, injected into the main view controller.
        let store = ServerStore()
        self.store = store

        let windowController = MainWindowController(store: store)
        self.windowController = windowController
        windowController.showWindow(nil)

        // Wire the shared recording controller into the UI layer. AppDelegate owns these
        // closures (Stage B will also have it own the floating panel + status item). Use
        // [weak windowController] so the closures never retain the window controller.
        let controller = RecordingController.shared

        controller.presentError = { [weak windowController] title, message in
            guard let mainVC = windowController?.window?.contentViewController as? MainViewController else {
                // Fall back to a modal alert if the window/VC is gone.
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            mainVC.presentAlert(title: title, text: message)
        }

        controller.isDeliveryAvailable = { [weak windowController] in
            (windowController?.window?.contentViewController as? MainViewController)?.activeTab != nil
        }

        controller.deliverFile = { [weak windowController] url, completion in
            guard let mainVC = windowController?.window?.contentViewController as? MainViewController else {
                // No window/VC to deliver into: the file was never inserted or saved, so report
                // failure so the controller advances to .failed rather than hanging in .saving.
                completion(false)
                return
            }
            mainVC.deliverRecording(url, completion: completion)
        }

        // Stage B: create the floating recorder panel. It works on every supported OS
        // (14.0+) and simply keeps Start disabled (canStart == false) on macOS < 14.2 where
        // capture is unavailable.
        let recordingPanel = RecordingPanelController()
        self.recordingPanel = recordingPanel

        // The menu-bar status item is only useful where recording can actually happen
        // (macOS 14.2+). On older systems Start is always disabled, so adding the item would
        // just clutter the menu bar — skip it there.
        if controller.isSupported {
            let recordingStatusItem = RecordingStatusItem()
            // Route the menu-bar "Show Recorder Panel" to the panel without retaining it here.
            recordingStatusItem.onShowPanel = { [weak recordingPanel] in
                recordingPanel?.show()
            }
            self.recordingStatusItem = recordingStatusItem
        }

        // Auto-show the panel whenever a recording becomes active so the controls are
        // visible. Showing on any non-idle state (idempotent if already visible) is enough.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(recordingStateDidChange),
                                               name: .recordingStateDidChange,
                                               object: nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    // Show the floating recorder panel once a session becomes active (any non-idle phase).
    // The panel hides itself when the phase returns to idle (see RecordingPanelController).
    // Posted on the main thread by RecordingController.
    @objc private func recordingStateDidChange() {
        if RecordingController.shared.phase != .idle {
            recordingPanel?.show()
        }
    }

    // Shows the floating recorder panel. Reached via the responder chain from the
    // View ▸ "Show Recorder Panel" menu item (nil target).
    @objc func showRecorderPanel(_ sender: Any?) {
        recordingPanel?.show()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
