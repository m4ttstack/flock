import SwiftUI

/// The View menu's two tab-strip steps, which wrap at the strip's ends.
/// Menu only: the palette does not list them.
enum TabStepCommand: CaseIterable {
    case previous, next

    var title: String {
        switch self {
        case .previous: "Previous Tab"
        case .next: "Next Tab"
        }
    }

    var step: Int {
        switch self {
        case .previous: -1
        case .next: 1
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .previous: .leftArrow
        case .next: .rightArrow
        }
    }

    var modifiers: EventModifiers { [.command, .control] }

    var accessibilityIdentifier: String {
        switch self {
        case .previous: "flock.view.previousTab"
        case .next: "flock.view.nextTab"
        }
    }
}
