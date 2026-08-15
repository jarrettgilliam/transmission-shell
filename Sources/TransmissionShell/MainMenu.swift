import AppKit

/// Deliberately minimal — the web UI already offers everything about torrents, so this
/// covers only what a window needs.
///
/// Edit isn't optional: ⌘C/⌘V inside the web UI's own text fields are dispatched through
/// first-responder actions on these menu items, so omitting the menu breaks copy/paste in
/// the page.
@MainActor
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(applicationMenu(appName: appName))
        menu.addItem(editMenu())
        menu.addItem(viewMenu())

        let window = windowMenu()
        menu.addItem(window)
        NSApplication.shared.windowsMenu = window.submenu

        return menu
    }

    private static func applicationMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: appName)

        submenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = submenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.submenu = submenu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Edit")

        submenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = submenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        submenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        submenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        submenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        submenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        item.submenu = submenu
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "View")

        submenu.addItem(
            withTitle: "Reload",
            action: #selector(AppDelegate.reloadWebUI(_:)),
            keyEquivalent: "r"
        )
        submenu.addItem(.separator())
        let fullScreen = submenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        item.submenu = submenu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Window")

        submenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        submenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        submenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        // AppKit appends "Bring All to Front" and the open windows below this.
        submenu.addItem(.separator())

        item.submenu = submenu
        return item
    }
}
