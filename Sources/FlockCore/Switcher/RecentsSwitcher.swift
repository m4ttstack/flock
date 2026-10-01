import Foundation
import Observation

public typealias WorkspaceSwitcher = RecentsSwitcher<WorkspaceID>
public typealias TabSwitcher = RecentsSwitcher<TabID>

/// A hold-and-tap switcher: ⌃Tab over workspaces, ⌥Tab over the selected
/// workspace's tabs. Keeps what was most recently selected across launches,
/// and, while the trigger is held, the rows on offer and which one letting go
/// will open.
@MainActor
@Observable
public final class RecentsSwitcher<ID: Hashable & Sendable & RawRepresentable<String>> {
    public static var storedLimit: Int { 50 }

    /// Most recent first, without repeats. An item that has since closed
    /// stays until it ages out; `begin` skips it.
    public private(set) var recents: [ID]
    /// The rows while the trigger is held, the current item first. Empty
    /// otherwise.
    public private(set) var order: [ID] = []
    public private(set) var selection = 0
    /// Held back until a moment after the first tap, so a quick tap goes back
    /// to the last item without the panel flashing up.
    public private(set) var isShown = false
    /// Which press a delayed `show` belongs to.
    public private(set) var session = 0

    public var isActive: Bool { !order.isEmpty }
    public var selected: ID? { order.indices.contains(selection) ? order[selection] : nil }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let defaultsKey: String

    public init(defaultsKey: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        recents = (userDefaults.stringArray(forKey: defaultsKey) ?? []).compactMap(ID.init(rawValue:))
    }

    public func note(_ id: ID) {
        guard recents.first != id else { return }
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.storedLimit { recents.removeLast(recents.count - Self.storedLimit) }
        userDefaults.set(recents.map(\.rawValue), forKey: defaultsKey)
    }

    /// Selects the item before this one, or with `reverse` the last row.
    /// Returns false, and starts nothing, when there is nowhere to go.
    @discardableResult
    public func begin(items: [ID], current: ID?, reverse: Bool = false) -> Bool {
        let known = Set(items)
        var rows = recents.filter { known.contains($0) && $0 != current }
        if let current, known.contains(current) { rows.insert(current, at: 0) }
        rows += items.filter { !rows.contains($0) }
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

    public func select(_ id: ID) {
        if let index = order.firstIndex(of: id) { selection = index }
    }

    public func show(session: Int) {
        if isActive, session == self.session { isShown = true }
    }

    /// Ends the switch and names where to go: nil when the selection is back
    /// on the item it started from.
    public func finish() -> ID? {
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

extension RecentsSwitcher where ID == WorkspaceID {
    public static var defaultsKey: String { "flock.workspaceRecents" }

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(defaultsKey: Self.defaultsKey, userDefaults: userDefaults)
    }

    @discardableResult
    public func begin(workspaces: [WorkspaceID], current: WorkspaceID?, reverse: Bool = false) -> Bool {
        begin(items: workspaces, current: current, reverse: reverse)
    }

    /// The workspaces ⌃Tab offers: every one but a herd's, which the rail
    /// keeps out of its list too. The current one stays even when it is a
    /// herd, since `begin` reads the first row as where the switch started.
    public static func candidates(_ workspaces: [WorkspaceRecord], current: WorkspaceID?) -> [WorkspaceID] {
        workspaces
            .filter { $0.workspaceID == current || !HerdWorkspace.isHerd(label: $0.label) }
            .map(\.workspaceID)
    }
}

extension RecentsSwitcher where ID == TabID {
    public static var defaultsKey: String { "flock.tabRecents" }

    /// One list across every workspace: tab ids are unique across them, and
    /// `begin` is only ever handed one workspace's tabs.
    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(defaultsKey: Self.defaultsKey, userDefaults: userDefaults)
    }

    /// A tab's row title. herdr labels an unnamed tab with a number, which
    /// says nothing in a list ordered by use, so such a tab shows its focused
    /// pane's title in brackets instead.
    public static func title(for tab: TabRecord, in model: SessionModel) -> String {
        guard TabTitle.isAutoNamed(tab.label) else { return tab.label }
        let paneID = model.layouts[tab.tabID]?.focusedPaneID ?? model.layouts[tab.tabID]?.panes.first?.paneID
        guard let pane = paneID.flatMap({ model.panes[$0] }) else { return tab.label }
        return "[\(pane.displayTitle)]"
    }
}

/// The modifier that holds a switcher open: ⌃ for workspaces, ⌥ for tabs.
public enum SwitcherTrigger: Sendable {
    case control, option
}

/// The keys a switcher takes. Its trigger plus Tab, with Shift to go back,
/// starts or steps it; while it is up, the arrows step, Return opens, Esc
/// cancels, and every other key is held back from the pane behind.
public enum SwitcherKey {
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
        trigger: SwitcherTrigger, keyCode: UInt16, control: Bool, shift: Bool, command: Bool, option: Bool, active: Bool
    ) -> Decision {
        let triggerOnly = switch trigger {
        case .control: control && !option
        case .option: option && !control
        }
        if keyCode == tab, triggerOnly, !command { return shift ? .previous : .next }
        guard active else { return .pass }
        switch keyCode {
        case escape: return .cancel
        case returnKey, keypadEnter: return .commit
        case downArrow, rightArrow: return .next
        case upArrow, leftArrow: return .previous
        default: return .swallow
        }
    }

    public static func isHeld(_ trigger: SwitcherTrigger, control: Bool, option: Bool) -> Bool {
        switch trigger {
        case .control: control
        case .option: option
        }
    }
}
