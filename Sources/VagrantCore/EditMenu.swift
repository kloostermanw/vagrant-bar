import AppKit

/// Text fields only receive ⌘V, ⌘C etc. through key equivalents in the main menu. An app
/// started without the SwiftUI `App` lifecycle gets no main menu, so those shortcuts do
/// nothing. As an accessory app the menu bar is never shown; the menu only routes shortcuts.
@MainActor
public enum EditMenu {
    public static func make() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", "undo:", "z"))
        menu.addItem(item("Redo", "redo:", "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", "cut:", "x"))
        menu.addItem(item("Copy", "copy:", "c"))
        menu.addItem(item("Paste", "paste:", "v"))
        menu.addItem(item("Select All", "selectAll:", "a"))
        return menu
    }

    /// A main menu holding only the Edit menu, for `NSApp.mainMenu`.
    public static func mainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = make()
        mainMenu.addItem(editItem)
        return mainMenu
    }

    /// Items have no target, so the action goes to the first responder (the focused field).
    private static func item(_ title: String, _ action: String, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
