import AppKit
import XCTest
@testable import VagrantCore

@MainActor
final class EditMenuTests: XCTestCase {
    private func item(_ action: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == NSSelectorFromString(action) }
    }

    private func assertItem(_ action: String, key: String, modifiers: NSEvent.ModifierFlags = .command,
                            in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) {
        guard let item = item(action, in: menu) else {
            return XCTFail("No menu item for \(action)", file: file, line: line)
        }
        XCTAssertEqual(item.keyEquivalent, key, file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, file: file, line: line)
        // A nil target sends the action to the first responder, i.e. the focused text field.
        XCTAssertNil(item.target, file: file, line: line)
    }

    func testEditMenuHasStandardTextShortcuts() {
        let menu = EditMenu.make()
        assertItem("undo:", key: "z", in: menu)
        assertItem("redo:", key: "z", modifiers: [.command, .shift], in: menu)
        assertItem("cut:", key: "x", in: menu)
        assertItem("copy:", key: "c", in: menu)
        assertItem("paste:", key: "v", in: menu)
        assertItem("selectAll:", key: "a", in: menu)
    }

    func testMainMenuContainsEditMenuAsSubmenu() {
        // Key equivalents are only looked up through the main menu's submenus.
        let mainMenu = EditMenu.mainMenu()
        let edit = mainMenu.items.compactMap(\NSMenuItem.submenu).first { $0.title == "Edit" }
        XCTAssertNotNil(edit)
        XCTAssertNotNil(edit.flatMap { item("paste:", in: $0) })
    }
}
