import Foundation
import Observation

/// What a right click on a pane's ghostty surface should do, decided PURELY
/// from the click's own Option state, whether the pane app has asked for
/// mouse reporting, and whether the pane is flock's focused one -- no view,
/// event object, or libghostty call inside this type, so the decision is
/// testable with no `NSEvent`/`NSView` anywhere.
public enum RightClickDisposition: Equatable, Sendable {
    /// Present herdr's own action menu (Split/Close/...): `GhosttySurfaceView`
    /// hands the event back to the responder chain, which asks it for a menu
    /// via `menu(for:)` (built by its `paneMenuProvider`).
    case menu
    /// Send the click into the pane's own program. `GhosttySurfaceView`
    /// routes it through `MouseForwarding`, which turns it into a
    /// `terminal.mouse` line on the control FIFO (capture is on whenever this
    /// is returned).
    case forwardToPane
    /// Neither the menu nor the pane: rearrange mode owns the whole pane as a
    /// drag surface, so a right-click there does nothing on its own -- it is
    /// drag input like any other point on the pane.
    case suppressed

    /// The rule:
    /// - Rearrange mode active: always `.suppressed`, before anything else.
    /// - Not flock's focused pane: `.menu`. herdr reports mouse capture to
    ///   every attached pane, focused or not, and `MouseForwarding` drops
    ///   every event for an unfocused pane, so forwarding here would leave the
    ///   click with nowhere to go at all.
    /// - Capture OFF: `.menu`. Nothing is listening in the pane, so the click
    ///   falls through to the menu rather than disappearing into a plain shell.
    /// - Otherwise the pane's `mode` picks the plain click's route and Option
    ///   takes the other one, except in the rt modal, which has no menu.
    public static func decide(
        optionHeld: Bool,
        captureEnabled: Bool,
        paneIsFocused: Bool,
        rearrangeActive: Bool = false,
        mode: RightClickMode = .program
    ) -> RightClickDisposition {
        guard !rearrangeActive else { return .suppressed }
        guard paneIsFocused, captureEnabled else { return .menu }
        switch mode {
        case .menu: return optionHeld ? .forwardToPane : .menu
        case .program: return optionHeld ? .menu : .forwardToPane
        case .programOnly: return .forwardToPane
        }
    }
}

/// Where a plain right-click goes in a pane whose program has the mouse.
public enum RightClickMode: CaseIterable, Equatable, Sendable {
    /// flock's menu; Option sends the click to the program.
    case menu
    /// The program; Option opens flock's menu.
    case program
    /// The program, Option or not: the rt modal has no menu to open.
    case programOnly
}

/// Each canvas pane's right-click mode, keyed by its terminal so a pane keeps
/// its mode across moves. Only `.menu` is stored; every other pane's
/// right-clicks go to its program. `userDefaults` nil keeps it in memory.
@MainActor
@Observable
public final class RightClickModeStore {
    public static let defaultsKey = "flock.rightClicksToMenu"

    private var toMenu: Set<TerminalID>
    @ObservationIgnored private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults
        let stored = userDefaults?.stringArray(forKey: Self.defaultsKey) ?? []
        toMenu = Set(stored.map(TerminalID.init(rawValue:)))
    }

    public func mode(for terminal: TerminalID?) -> RightClickMode {
        guard let terminal, toMenu.contains(terminal) else { return .program }
        return .menu
    }

    public func toggle(_ terminal: TerminalID) {
        if toMenu.remove(terminal) == nil { toMenu.insert(terminal) }
        save()
    }

    public func keepOnly(_ present: Set<TerminalID>) {
        let kept = toMenu.intersection(present)
        guard kept != toMenu else { return }
        toMenu = kept
        save()
    }

    private func save() {
        userDefaults?.set(toMenu.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    }
}
