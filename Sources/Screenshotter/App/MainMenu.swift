import AppKit

/// The menu bar shown while the app is in the foreground (editor/history open). It also provides the
/// standard Edit key equivalents (⌘Z, ⌘C, ⌘V…) that text editing and the canvas rely on.
@MainActor
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = submenu(in: mainMenu, title: "Screenshotter")
        appMenu.addItem(withTitle: "About Screenshotter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings), ",", target: delegate))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Screenshotter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Screenshotter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu(in: mainMenu, title: "File")
        fileMenu.addItem(item("Capture Area", #selector(AppDelegate.captureAreaFromMenu), "", target: delegate))
        fileMenu.addItem(item("Capture Full Screen", #selector(AppDelegate.captureFullScreenFromMenu), "", target: delegate))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Save As…", #selector(EditorWindowController.saveImage(_:)), "s"))
        fileMenu.addItem(item("Done", #selector(EditorWindowController.done), "\r", modifiers: [.command]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        let editMenu = submenu(in: mainMenu, title: "Edit")
        editMenu.addItem(item("Undo", Selector(("undo:")), "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let windowMenu = submenu(in: mainMenu, title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("History", #selector(AppDelegate.showHistory), "y", target: delegate))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private static func submenu(in parent: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String,
        modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
