import AppKit
import DocmostCore

// Owns the main window and installs MainViewController as its content view controller.
final class MainWindowController: NSWindowController {

    init(store: ServerStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "gitmost"
        window.contentViewController = MainViewController(store: store)

        super.init(window: window)

        // Restore the saved frame, then enable autosave. setFrameAutosaveName persists
        // size/position changes automatically, but for a programmatically created window
        // it does NOT restore them — so restore explicitly first via setFrameUsingName.
        let autosaveName = NSWindow.FrameAutosaveName("DocmostMainWindow")
        if !window.setFrameUsingName(autosaveName) {
            window.center()   // no saved frame yet -> center on first launch
        }
        window.setFrameAutosaveName(autosaveName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
