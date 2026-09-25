import Foundation
import Observation

/// ⌃Tab's workspace switcher: the workspaces most recently selected, kept
/// across launches, and, while ⌃ is held, the rows on offer and which one
/// letting go will open.
@MainActor
@Observable
public final class WorkspaceSwitcher {
    public static let defaultsKey = "flock.workspaceRecents"
    public static let storedLimit = 50

    /// Most recent first, without repeats. A workspace that has since closed
    /// stays until it ages out; `begin` skips it.
    public private(set) var recents: [WorkspaceID]
    /// The rows while ⌃ is held, the current workspace first. Empty otherwise.
    public private(set) var order: [WorkspaceID] = []
    public private(set) var selection = 0
    /// Held back until a moment after ⌃Tab, so a quick tap goes back to the
    /// last workspace without the panel flashing up.
    public private(set) var isShown = false
    /// Which press of ⌃Tab a delayed `show` belongs to.
    public private(set) var session = 0

    public var isActive: Bool { !order.isEmpty }
    public var selected: WorkspaceID? { order.indices.contains(selection) ? order[selection] : nil }

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        recents = (userDefaults.stringArray(forKey: Self.defaultsKey) ?? []).map(WorkspaceID.init(rawValue:))
    }

    public func note(_ id: WorkspaceID) {
        guard recents.first != id else { return }
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.storedLimit { recents.removeLast(recents.count - Self.storedLimit) }
        userDefaults.set(recents.map(\.rawValue), forKey: Self.defaultsKey)
    }

    /// The workspaces ⌃Tab offers: every one but a herd's, which the rail
    /// keeps out of its list too. The current one stays even when it is a
    /// herd, since `begin` reads the first row as where the switch started.
    public static func candidates(_ workspaces: [WorkspaceRecord], current: WorkspaceID?) -> [WorkspaceID] {
        workspaces
            .filter { $0.workspaceID == current || !HerdWorkspace.isHerd(label: $0.label) }
            .map(\.workspaceID)
    }

    /// Selects the workspace before this one, or with `reverse` the last row.
    /// Returns false, and starts nothing, when there is nowhere to go.
    @discardableResult
    public func begin(workspaces: [WorkspaceID], current: WorkspaceID?, reverse: Bool = false) -> Bool {
        let known = Set(workspaces)
        var rows = recents.filter { known.contains($0) && $0 != current }
        if let current, known.contains(current) { rows.insert(current, at: 0) }
        rows += workspaces.filter { !rows.contains($0) }
        guard rows.count > 1 else { return false }
        session += 1
        order = rows
        selection = reverse ? rows.count - 1 : 1
        isShown = false
        return true
    }

    public func step(_ delta: Int) {
        guard isActive else { return }
        selection = ((selection + delta) % order.count + order.count) % order.count
    }

    public func select(_ id: WorkspaceID) {
        if let index = order.firstIndex(of: id) { selection = index }
    }

    public func show(session: Int) {
        if isActive, session == self.session { isShown = true }
    }

    /// Ends the switch and names where to go: nil when the selection is back
    /// on the workspace it started from.
    public func finish() -> WorkspaceID? {
        let target = selection == 0 ? nil : selected
        cancel()
        return target
    }

    public func cancel() {
        order = []
        selection = 0
        isShown = false
    }
}

/// The keys the switcher takes. ⌃Tab and ⌃⇧Tab start or step it; while it
/// is up, the arrows step, Return opens, Esc cancels, and every other key is
/// held back from the pane behind.
public enum WorkspaceSwitcherKey {
    public enum Decision: Equatable, Sendable { case next, previous, commit, cancel, swallow, pass }

    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    public static func decide(
        keyCode: UInt16, control: Bool, shift: Bool, command: Bool, option: Bool, active: Bool
    ) -> Decision {
        if keyCode == tab, control, !command, !option { return shift ? .previous : .next }
        guard active else { return .pass }
        switch keyCode {
        case escape: return .cancel
        case returnKey, keypadEnter: return .commit
        case downArrow, rightArrow: return .next
        case upArrow, leftArrow: return .previous
        default: return .swallow
        }
    }
}
