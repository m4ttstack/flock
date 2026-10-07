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

    func testThePaletteTakesCommandK() {
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.commandPalette.key, modifiers: ViewCommand.commandPalette.modifiers), "⌘K")
    }

    func testJOpensTheOldestBracketsLeaveAndAdvanceTheFocusedViewAndClearIsU() {
        XCTAssertEqual(ViewCommand.openOldestNotification.key, "j")
        XCTAssertEqual(ViewCommand.openOldestNotification.modifiers, .command)
        XCTAssertFalse(ViewCommand.allCases.contains { $0.key == "j" && $0.modifiers == [.command, .shift] }, "Jump Back is retired")
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.backToOverview.key, modifiers: ViewCommand.backToOverview.modifiers), "⌘[")
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.openNextCard.key, modifiers: ViewCommand.openNextCard.modifiers), "⌘]")
        XCTAssertEqual(ViewCommand.clearNotifications.key, "u")
        XCTAssertEqual(ViewCommand.clearNotifications.modifiers, [.command, .shift])
    }

    func testCommandDigitsPickTheViewsInTabOrder() {
        let labels = ViewTab.allCases.map { tab in
            let command = ViewCommand.show(tab)
            XCTAssertEqual(command.viewTab, tab)
            XCTAssertEqual(command.title, tab.title)
            return ShortcutLabel.text(key: command.key, modifiers: command.modifiers)
        }
        XCTAssertEqual(labels, ["⌘1", "⌘2", "⌘3"])
        XCTAssertEqual(ShortcutLabel.text(key: ViewCommand.allWorkspaces.key, modifiers: ViewCommand.allWorkspaces.modifiers), "⇧⌘R")
    }

    /// Every menu-bar shortcut flock sets, from every list, is distinct.
    func testNoTwoMenuShortcutsCollide() {
        var labels = ViewCommand.allCases.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += FocusedPaneCommand.all.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: $0.modifiers) }
        labels += PaneDirectionCommand.all.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        labels += StepCommand.allCases.map { ShortcutLabel.text(key: $0.key, modifiers: $0.modifiers) }
        for index in 0..<GoToCommand.limit {
            labels.append(ShortcutLabel.text(key: GoToCommand.key(at: index), modifiers: GoToCommand.tabModifiers))
            labels.append(ShortcutLabel.text(key: GoToCommand.key(at: index), modifiers: GoToCommand.workspaceModifiers))
        }
        labels += ChatMenuItem.allCases.map { ShortcutLabel.text(key: KeyEquivalent($0.key), modifiers: [.command, .shift]) }
        labels += ["⌥⌘M", "F2", "⌘Z", "⇧⌘Z"]
        XCTAssertEqual(labels.count, Set(labels).count, "duplicates: \(labels.filter { label in labels.filter { $0 == label }.count > 1 })")
        // The launcher's keys are the views' keys while a new pane offers it,
        // and only those: the menu hands them to one or the other.
        let viewKeys = Set(ViewTab.allCases.map { ShortcutLabel.text(key: ViewCommand.show($0).key, modifiers: ViewCommand.show($0).modifiers) })
        for index in 0..<GoToCommand.limit {
            let launch = ShortcutLabel.text(key: LauncherSlots.key(at: index), modifiers: .command)
            XCTAssertTrue(!labels.contains(launch) || viewKeys.contains(launch), "\(launch) is taken by something other than a view")
        }
    }

    func testTheRightClickToggleIsTitledForWhatItWillDo() {
        XCTAssertEqual(RightClickToggle.title(for: .program), "Give Right-Clicks to Flock")
        XCTAssertEqual(RightClickToggle.title(for: .menu), "Send Right-Clicks to Program")
    }
}
