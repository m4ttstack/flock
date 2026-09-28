import SwiftUI

/// The Window menu's strip and rail steps, which wrap at either end. Left and
/// right walk the tab strip, up and down walk the rail, the way each is laid
/// out. Menu only: the palette does not list them.
enum StepCommand: CaseIterable {
    case previousTab, nextTab, previousWorkspace, nextWorkspace

    var title: String {
        switch self {
        case .previousTab: "Previous Tab"
        case .nextTab: "Next Tab"
        case .previousWorkspace: "Previous Workspace"
        case .nextWorkspace: "Next Workspace"
        }
    }

    var step: Int {
        switch self {
        case .previousTab, .previousWorkspace: -1
        case .nextTab, .nextWorkspace: 1
        }
    }

    var isTab: Bool { self == .previousTab || self == .nextTab }

    var key: KeyEquivalent {
        switch self {
        case .previousTab: .leftArrow
        case .nextTab: .rightArrow
        case .previousWorkspace: .upArrow
        case .nextWorkspace: .downArrow
        }
    }

    var modifiers: EventModifiers { [.command, .control] }

    var accessibilityIdentifier: String {
        switch self {
        case .previousTab: "flock.window.previousTab"
        case .nextTab: "flock.window.nextTab"
        case .previousWorkspace: "flock.window.previousWorkspace"
        case .nextWorkspace: "flock.window.nextWorkspace"
        }
    }
}

/// Go to Tab and Go to Workspace: the nth tab on the strip under Control,
/// the nth rail row under Control+Command. A number past the last one has no
/// item, so the key reaches the pane's program instead.
enum GoToCommand {
    static let limit = 9

    static let tabModifiers: EventModifiers = .control
    static let workspaceModifiers: EventModifiers = [.control, .command]

    static func key(at index: Int) -> KeyEquivalent {
        KeyEquivalent(Character(String(index + 1)))
    }
}
