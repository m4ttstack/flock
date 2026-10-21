import Foundation
import Observation

/// The three things flock creates that start a new shell.
public enum NewTerminalKind: String, CaseIterable, Sendable {
    case workspace
    case tab
    case pane

    public var displayName: String {
        switch self {
        case .workspace: "New Workspace"
        case .tab: "New Tab"
        case .pane: "New Pane"
        }
    }

    /// A new tab is usually a step back out of a worktree to start something
    /// else; a new pane or workspace usually carries on where the pane is.
    public var defaultFolder: StartingFolder {
        self == .tab ? .mainCheckout : .currentPane
    }
}

public enum StartingFolder: String, CaseIterable, Sendable {
    case currentPane
    case mainCheckout
    case home
    case custom

    public var displayName: String {
        switch self {
        case .currentPane: "Current Pane's Folder"
        case .mainCheckout: "Repo's Main Checkout"
        case .home: "Home Folder"
        case .custom: "Custom Folder…"
        }
    }

    public var needsPaneFolder: Bool { self == .mainCheckout }
}

public struct StartingFolderChoice: Equatable, Sendable {
    public var folder: StartingFolder
    /// Kept while another folder is chosen, so going back to custom finds it.
    public var customPath: String?

    public init(folder: StartingFolder, customPath: String? = nil) {
        self.folder = folder
        self.customPath = customPath
    }

    /// The `cwd` a create request carries, or nil to send none: herdr then
    /// follows the focused pane itself. `paneFolder` is that pane's live
    /// folder, read only when `folder.needsPaneFolder`. Touches the disk, so
    /// it is run off the main actor.
    public func cwd(paneFolder: String?, home: String) -> String? {
        switch folder {
        case .currentPane:
            return nil
        case .home:
            return home
        case .mainCheckout:
            return paneFolder.flatMap(MainCheckout.resolve(from:)) ?? home
        case .custom:
            var isDirectory: ObjCBool = false
            guard let customPath, FileManager.default.fileExists(atPath: customPath, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return home }
            return customPath
        }
    }
}

/// The Settings choice per kind, persisted across launches in the same
/// UserDefaults pattern as `RearrangeAfterMoveStore`.
@MainActor
@Observable
public final class StartingFolderStore {
    public static func defaultsKey(for kind: NewTerminalKind) -> String {
        "flock.startingFolder.\(kind.rawValue)"
    }

    public static func customPathKey(for kind: NewTerminalKind) -> String {
        "flock.startingFolder.\(kind.rawValue).customPath"
    }

    public static let startScreenFolderKey = "flock.startingFolder.startScreen"

    public private(set) var choices: [NewTerminalKind: StartingFolderChoice]
    public private(set) var startScreenLastPick: String?
    /// Picked on the start screen while this store lives, and so for every
    /// launch from it, whatever the setting says. Not persisted as such: the
    /// next session starts from the setting again.
    public private(set) var startScreenPick: String?

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        startScreenLastPick = userDefaults.string(forKey: Self.startScreenFolderKey)
        choices = Dictionary(uniqueKeysWithValues: NewTerminalKind.allCases.map { kind in
            let folder = userDefaults.string(forKey: Self.defaultsKey(for: kind)).flatMap(StartingFolder.init(rawValue:))
            return (kind, StartingFolderChoice(
                folder: folder ?? kind.defaultFolder,
                customPath: userDefaults.string(forKey: Self.customPathKey(for: kind))
            ))
        })
    }

    public func choice(for kind: NewTerminalKind) -> StartingFolderChoice {
        choices[kind] ?? StartingFolderChoice(folder: kind.defaultFolder)
    }

    public func select(_ folder: StartingFolder, for kind: NewTerminalKind) {
        choices[kind, default: choice(for: kind)].folder = folder
        userDefaults.set(folder.rawValue, forKey: Self.defaultsKey(for: kind))
    }

    public func selectCustom(path: String, for kind: NewTerminalKind) {
        choices[kind] = StartingFolderChoice(folder: .custom, customPath: path)
        userDefaults.set(StartingFolder.custom.rawValue, forKey: Self.defaultsKey(for: kind))
        userDefaults.set(path, forKey: Self.customPathKey(for: kind))
    }

    /// Where the start screen's first workspace opens: a folder picked there
    /// this session, else the New Workspace setting when it names a folder;
    /// following a pane or its main checkout has no pane to follow there, so
    /// the folder last picked on the screen stands in. Touches the disk.
    public func startScreenFolder(home: String) -> String {
        if let pick = startScreenPick, SessionViewModel.directoryExists(pick) { return pick }
        let choice = choice(for: .workspace)
        switch choice.folder {
        case .home, .custom:
            return choice.cwd(paneFolder: nil, home: home) ?? home
        case .currentPane, .mainCheckout:
            guard let last = startScreenLastPick, SessionViewModel.directoryExists(last) else { return home }
            return last
        }
    }

    public func pickStartScreenFolder(_ path: String) {
        startScreenPick = path
        startScreenLastPick = path
        userDefaults.set(path, forKey: Self.startScreenFolderKey)
    }
}
