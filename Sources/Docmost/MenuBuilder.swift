import AppKit

// Builds and installs the application's main menu programmatically.
// User-facing titles are in English. Standard selectors with nil targets are used
// for Edit/View items so they route through the responder chain to the focused view
// (this is what makes copy/paste work inside the gitmost web forms).
enum MenuBuilder {

    static func installMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())

        let windowItem = windowMenuItem()
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        // Let AppKit manage the Window menu (Minimize/Zoom + open windows list).
        if let windowSubmenu = windowItem.submenu {
            NSApp.windowsMenu = windowSubmenu
        }
    }

    // MARK: - App menu

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(withTitle: "About gitmost",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide gitmost",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")

        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit gitmost",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "File")

        // nil target -> routed through the responder chain to MainViewController.addServer(_:).
        let addServer = NSMenuItem(title: "Add Server…",
                                   action: #selector(MainViewController.addServer(_:)),
                                   keyEquivalent: "n")
        addServer.target = nil
        menu.addItem(addServer)

        menu.addItem(.separator())

        // Meeting recording (system audio + microphone). The dynamic title
        // (Start/Stop) is set by MainViewController.validateMenuItem. ⌘⇧R avoids
        // clashing with View ▸ Reload (⌘R). nil target -> responder chain.
        let record = NSMenuItem(title: "Start Recording",
                                action: #selector(MainViewController.toggleRecording(_:)),
                                keyEquivalent: "r")
        record.keyEquivalentModifierMask = [.command, .shift]
        record.target = nil
        menu.addItem(record)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Close Window",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")

        // All nil-targeted so they route to the current MainViewController.
        let reload = NSMenuItem(title: "Reload",
                                action: #selector(MainViewController.reloadCurrent(_:)),
                                keyEquivalent: "r")
        reload.target = nil
        menu.addItem(reload)

        let back = NSMenuItem(title: "Back",
                              action: #selector(MainViewController.goBack(_:)),
                              keyEquivalent: "[")
        back.target = nil
        menu.addItem(back)

        let forward = NSMenuItem(title: "Forward",
                                 action: #selector(MainViewController.goForward(_:)),
                                 keyEquivalent: "]")
        forward.target = nil
        menu.addItem(forward)

        menu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: #selector(MainViewController.zoomIn(_:)),
                                keyEquivalent: "+")
        zoomIn.target = nil
        menu.addItem(zoomIn)

        let zoomOut = NSMenuItem(title: "Zoom Out",
                                 action: #selector(MainViewController.zoomOut(_:)),
                                 keyEquivalent: "-")
        zoomOut.target = nil
        menu.addItem(zoomOut)

        let actualSize = NSMenuItem(title: "Actual Size",
                                    action: #selector(MainViewController.zoomReset(_:)),
                                    keyEquivalent: "0")
        actualSize.target = nil
        menu.addItem(actualSize)

        item.submenu = menu
        return item
    }

    // MARK: - Window menu

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        return item
    }
}
