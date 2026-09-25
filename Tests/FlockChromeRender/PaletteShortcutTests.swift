import SwiftUI
import XCTest
@testable import FlockCore

final class PaletteShortcutTests: XCTestCase {
    func testLabelsReadInApplesModifierOrder() {
        XCTAssertEqual(ShortcutLabel.text(key: "d", modifiers: .command), "⌘D")
        XCTAssertEqual(ShortcutLabel.text(key: "k", modifiers: [.command, .shift]), "⇧⌘K")
        XCTAssertEqual(ShortcutLabel.text(key: .leftArrow, modifiers: [.command, .option]), "⌥⌘←")
        XCTAssertEqual(ShortcutLabel.text(key: .downArrow, modifiers: [.command, .control, .shift]), "⌃⇧⌘↓")
        XCTAssertEqual(ShortcutLabel.text(key: .f2, modifiers: []), "F2")
    }

    func testThePaletteTakesCommandKAndClearNotificationsMoves() {
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.commandPalette.key, modifiers: ViewCommand.commandPalette.modifiers), "⌘K")
        XCTAssertEqual(
            ShortcutLabel.text(key: ViewCommand.clearNotifications.key, modifiers: ViewCommand.clearNotifications.modifiers), "⇧⌘K"
        )
    }

    /// Every menu-bar shortcut flock sets, from every list, is distinct.
    func testNoTwoMenuShortcutsCollide() {
        var labels = ViewCommand.allCases.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += FocusedPaneCommand.all.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers) }
        labels += PaneDirectionCommand.all.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += TabStepCommand.allCases.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += ChatMenuItem.allCases.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: [.command, .shift]) }
        labels += ["⌥⌘M", "F2", "⌘Z", "⇧⌘Z"]
        XCTAssertEqual(labels.count, Set(labels).count, "duplicates: \(labels.filter { label in labels.filter { $0 == label }.count > 1 })")
    }

    func testTheRightClickToggleIsTitledForWhatItWillDo() {
        XCTAssertEqual(RightClickToggle.title(for: .program), "Give Right-Clicks to Flock")
        XCTAssertEqual(RightClickToggle.title(for: .menu), "Send Right-Clicks to Program")
    }
}
