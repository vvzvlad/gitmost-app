import AppKit
import DocmostCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references so the window and the store stay alive for the app lifetime.
    private var windowController: MainWindowController?
    private var store: ServerStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the main menu first so standard Edit actions (copy/paste) work everywhere.
        MenuBuilder.installMainMenu()

        // Shared data store, injected into the main view controller.
        let store = ServerStore()
        self.store = store

        let windowController = MainWindowController(store: store)
        self.windowController = windowController
        windowController.showWindow(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
