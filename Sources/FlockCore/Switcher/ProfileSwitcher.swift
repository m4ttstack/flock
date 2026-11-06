import Foundation

public typealias ProfileSwitcher = RecentsSwitcher<ProfileID>

/// A `FlockProfile.id`, typed for `RecentsSwitcher`.
public struct ProfileID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

extension RecentsSwitcher where ID == ProfileID {
    public static var defaultsKey: String { "flock.profileRecents" }

    /// In the standard defaults rather than a profile's suite: the list spans
    /// profiles, and outlives every session a switch tears down.
    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(defaultsKey: Self.defaultsKey, userDefaults: userDefaults)
    }

    /// Every profile in the picker's order, local ones then machines, or none
    /// while a socket override pins the window to one server.
    public static func candidates(_ profiles: [FlockProfile], isLocked: Bool) -> [ProfileID] {
        guard !isLocked else { return [] }
        return (profiles.filter { !$0.isMachine } + profiles.filter(\.isMachine)).map { ProfileID(rawValue: $0.id) }
    }

    /// Called for every change of the current profile, whatever made it, so
    /// the first tap goes back to the one before.
    public func note(currentProfile id: String) {
        note(ProfileID(rawValue: id))
    }
}

public enum SwitcherKind: Hashable, Sendable {
    case workspaces, tabs, profiles, servers
}

/// What an idle switcher passes keys through for: a palette, rename editor,
/// rt modal or profile list open, or another switcher up.
public struct SwitcherBlockers: Equatable, Sendable {
    public var paletteOpen: Bool
    public var renaming: Bool
    public var rtModal: Bool
    public var profilePickerOpen: Bool
    public var active: Set<SwitcherKind>

    public init(
        paletteOpen: Bool = false, renaming: Bool = false, rtModal: Bool = false, profilePickerOpen: Bool = false,
        active: Set<SwitcherKind> = []
    ) {
        self.paletteOpen = paletteOpen
        self.renaming = renaming
        self.rtModal = rtModal
        self.profilePickerOpen = profilePickerOpen
        self.active = active
    }

    public func blocks(_ kind: SwitcherKind) -> Bool {
        paletteOpen || renaming || rtModal || profilePickerOpen || active.contains { $0 != kind }
    }
}
