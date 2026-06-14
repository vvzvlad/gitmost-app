import AppKit

// Builds and installs the application's main menu programmatically.
// User-facing titles are in Russian. Standard selectors with nil targets are used
// for Edit/View items so they route through the responder chain to the focused view
// (this is what makes copy/paste work inside the Docmost web forms).
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

        menu.addItem(withTitle: "О программе Docmost",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Скрыть",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")

        let hideOthers = NSMenuItem(title: "Скрыть остальные",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(withTitle: "Показать все",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Выйти из Docmost",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Файл", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Файл")

        // nil target -> routed through the responder chain to MainViewController.addServer(_:).
        let addServer = NSMenuItem(title: "Добавить сервер…",
                                   action: #selector(MainViewController.addServer(_:)),
                                   keyEquivalent: "n")
        addServer.target = nil
        menu.addItem(addServer)

        menu.addItem(withTitle: "Закрыть окно",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Правка")

        menu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Вид", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Вид")

        // All nil-targeted so they route to the current MainViewController.
        let reload = NSMenuItem(title: "Обновить",
                                action: #selector(MainViewController.reloadCurrent(_:)),
                                keyEquivalent: "r")
        reload.target = nil
        menu.addItem(reload)

        let back = NSMenuItem(title: "Назад",
                              action: #selector(MainViewController.goBack(_:)),
                              keyEquivalent: "[")
        back.target = nil
        menu.addItem(back)

        let forward = NSMenuItem(title: "Вперёд",
                                 action: #selector(MainViewController.goForward(_:)),
                                 keyEquivalent: "]")
        forward.target = nil
        menu.addItem(forward)

        item.submenu = menu
        return item
    }

    // MARK: - Window menu

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Окно", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Окно")

        menu.addItem(withTitle: "Свернуть",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Масштаб",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        return item
    }
}
