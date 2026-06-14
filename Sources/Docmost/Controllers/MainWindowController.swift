import AppKit

// Owns the main window and installs MainViewController as its content view controller.
final class MainWindowController: NSWindowController {

    init(store: ServerStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Docmost"
        window.contentViewController = MainViewController(store: store)
        window.setFrameAutosaveName("DocmostMainWindow")

        super.init(window: window)

        // On first launch there is no saved frame, so the window sits at origin (0,0) —
        // center it. On later launches the autosave name restores the saved frame.
        if window.frame.origin == .zero {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
