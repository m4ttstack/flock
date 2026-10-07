import Foundation
import Observation

extension PaneRecord {
    /// What flock calls a pane wherever it names one: the name the user gave
    /// it (herdr's label), then the title its program sets, which Claude Code
    /// keeps rewriting and so must never hide a name.
    public var displayTitle: String {
        [label, terminalTitleStripped].compactMap { $0 }.first { !$0.isEmpty } ?? "shell"
    }
}

/// Settings > Titles > "One title for a one-pane tab". While it is on, a pane
/// alone in its tab has no title of its own anywhere flock names it: the
/// tab's title (`TabTitle`) is the one title, and renaming the pane renames
/// the tab. Display only: herdr's labels are never changed by the setting.
///
/// The tab's panes are counted from the model, never from what is drawn, so
/// a zoomed tab of two still names both of its panes.
public enum PaneNaming {
    /// The tab whose title stands for `pane`'s, or nil when the pane keeps its own.
    public static func titleTab(of pane: PaneRecord, model: SessionModel, oneTitle: Bool) -> TabRecord? {
        guard oneTitle, paneCount(pane.tabID, model: model) == 1 else { return nil }
        return model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }
    }

    /// The pane's own title where a surface draws one; nil where the tab's
    /// title stands for it and the surface draws no title.
    public static func shownTitle(pane: PaneRecord, model: SessionModel, oneTitle: Bool) -> String? {
        titleTab(of: pane, model: model, oneTitle: oneTitle) == nil ? pane.displayTitle : nil
    }

    /// What a surface that names the pane once calls it: the tab's title for
    /// a pane that has none of its own, else the pane's.
    public static func name(pane: PaneRecord, model: SessionModel, oneTitle: Bool) -> String {
        titleTab(of: pane, model: model, oneTitle: oneTitle).map { TabTitle.resolve($0, in: model).text } ?? pane.displayTitle
    }

    public struct CardTitles: Equatable, Sendable {
        public let title: String
        /// The small second line, nil when it would repeat the title.
        public let detail: String?

        public init(title: String, detail: String?) {
            self.title = title
            self.detail = detail
        }
    }

    /// An Overview card's lines. On, the tab's title leads and a pane sharing
    /// its tab adds its own title below. Off, the pane's title leads and the
    /// tab's follows. A tab herdr only numbered says nothing, so a number
    /// never leads and never fills the second line.
    public static func cardTitles(pane: PaneRecord, model: SessionModel, oneTitle: Bool) -> CardTitles {
        guard let tab = model.tabs[pane.workspaceID]?.first(where: { $0.tabID == pane.tabID }) else {
            return CardTitles(title: pane.displayTitle, detail: nil)
        }
        let resolved = TabTitle.resolve(tab, in: model)
        let tabTitle: String? = resolved.isFromPane || !TabTitle.isAutoNamed(resolved.text) ? resolved.text : nil
        func differs(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) != .orderedSame }
        if oneTitle, let tabTitle {
            let shared = paneCount(pane.tabID, model: model) >= 2
            return CardTitles(title: tabTitle, detail: shared && differs(pane.displayTitle, tabTitle) ? pane.displayTitle : nil)
        }
        if oneTitle {
            return CardTitles(title: pane.displayTitle, detail: nil)
        }
        return CardTitles(
            title: pane.displayTitle,
            detail: tabTitle.flatMap { differs($0, pane.displayTitle) ? $0 : nil }
        )
    }

    /// What a rename opened on `target` really renames: a pane with no title
    /// of its own renames its tab.
    public static func renameTarget(_ target: RenameTarget, model: SessionModel?, oneTitle: Bool) -> RenameTarget {
        guard case .pane(let paneID) = target, let model, let pane = model.panes[paneID],
              let tab = titleTab(of: pane, model: model, oneTitle: oneTitle)
        else { return target }
        return .tab(tab.tabID)
    }

    static func paneCount(_ tab: TabID, model: SessionModel) -> Int {
        model.panes.values.reduce(0) { $0 + ($1.tabID == tab ? 1 : 0) }
    }
}

/// The Settings toggle, persisted like `NotificationLifetimeStore`. On by default.
@MainActor
@Observable
public final class OneTitleStore {
    public static let defaultsKey = "flock.oneTitleForOnePaneTab"

    public private(set) var active: Bool

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        active = userDefaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    public func select(_ value: Bool) {
        active = value
        userDefaults.set(value, forKey: Self.defaultsKey)
    }
}
