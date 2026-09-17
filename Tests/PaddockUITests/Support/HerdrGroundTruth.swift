import Foundation

/// A pane's cell rect inside its tab's layout.
struct HerdrRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// One `session.snapshot` result, read by key the way the shell harness reads
/// it with jq.
///
/// `tabs` and `panes` are FLAT lists carrying their own `workspace_id` /
/// `tab_id`, not children nested under a workspace object, and `layouts` is a
/// third flat list keyed by `tab_id`.
struct HerdrSnapshotJSON {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    private var workspaces: [[String: Any]] { raw["workspaces"] as? [[String: Any]] ?? [] }
    private var tabs: [[String: Any]] { raw["tabs"] as? [[String: Any]] ?? [] }
    private var panes: [[String: Any]] { raw["panes"] as? [[String: Any]] ?? [] }
    private var layouts: [[String: Any]] { raw["layouts"] as? [[String: Any]] ?? [] }

    var focusedWorkspaceID: String? { raw["focused_workspace_id"] as? String }
    var focusedTabID: String? { raw["focused_tab_id"] as? String }
    var focusedPaneID: String? { raw["focused_pane_id"] as? String }

    var workspaceCount: Int { workspaces.count }

    func orderedWorkspaceLabels() -> [String] {
        workspaces.compactMap { $0["label"] as? String }
    }

    func orderedWorkspaceIDs() -> [String] {
        workspaces.compactMap { $0["workspace_id"] as? String }
    }

    func tabIDs(inWorkspace workspaceID: String) -> [String] {
        tabs.filter { $0["workspace_id"] as? String == workspaceID }
            .compactMap { $0["tab_id"] as? String }
    }

    func tabCount(inWorkspace workspaceID: String) -> Int {
        tabIDs(inWorkspace: workspaceID).count
    }

    func label(ofTab tabID: String) -> String? {
        tabs.first { $0["tab_id"] as? String == tabID }?["label"] as? String
    }

    func paneIDs(inTab tabID: String) -> [String] {
        panes.filter { $0["tab_id"] as? String == tabID }
            .compactMap { $0["pane_id"] as? String }
    }

    func paneCount(inTab tabID: String) -> Int {
        paneIDs(inTab: tabID).count
    }

    func isZoomed(tab tabID: String) -> Bool {
        layout(ofTab: tabID)?["zoomed"] as? Bool ?? false
    }

    /// The ratio of the tab's ROOT split, which is the one a divider drag on
    /// a two-pane tab moves. A tab with no split has none.
    func layoutRatio(tab tabID: String) -> Double? {
        guard let splits = layout(ofTab: tabID)?["splits"] as? [[String: Any]],
              let root = splits.first else { return nil }
        return (root["ratio"] as? NSNumber)?.doubleValue
    }

    /// The pane's rect as its own tab's layout states it, in herdr's terminal
    /// cells (not points): a composition case reads these to say which side
    /// of the tab a moved pane landed on.
    func paneRect(_ paneID: String) -> HerdrRect? {
        for layout in layouts {
            guard let panes = layout["panes"] as? [[String: Any]] else { continue }
            guard let pane = panes.first(where: { $0["pane_id"] as? String == paneID }),
                  let rect = pane["rect"] as? [String: Any] else { continue }
            guard let x = (rect["x"] as? NSNumber)?.intValue,
                  let y = (rect["y"] as? NSNumber)?.intValue,
                  let width = (rect["width"] as? NSNumber)?.intValue,
                  let height = (rect["height"] as? NSNumber)?.intValue else { return nil }
            return HerdrRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    /// The tab a pane belongs to, which is how a case checks that a moved
    /// pane landed where it was aimed rather than only that some count moved.
    func tabID(ofPane paneID: String) -> String? {
        panes.first { $0["pane_id"] as? String == paneID }?["tab_id"] as? String
    }

    func workspaceID(ofPane paneID: String) -> String? {
        panes.first { $0["pane_id"] as? String == paneID }?["workspace_id"] as? String
    }

    func allPaneIDs() -> [String] {
        panes.compactMap { $0["pane_id"] as? String }
    }

    /// Every split direction in the tab's layout, outermost first. A tab with
    /// one pane has none.
    func splitDirections(inTab tabID: String) -> [String] {
        guard let splits = layout(ofTab: tabID)?["splits"] as? [[String: Any]] else { return [] }
        return splits.compactMap { $0["direction"] as? String }
    }

    /// The whole arrangement on one line, for a failure message: every
    /// workspace with its tabs, and every tab with its panes in snapshot
    /// order. A blind assertion failure is only as useful as what it can say
    /// herdr actually held.
    func outline() -> String {
        orderedWorkspaceIDs().map { workspace in
            let label = workspaces.first { $0["workspace_id"] as? String == workspace }?["label"] as? String ?? "?"
            let tabs = tabIDs(inWorkspace: workspace).map { tab in
                "\(tab)[\(self.label(ofTab: tab) ?? "?")]{\(paneIDs(inTab: tab).joined(separator: ","))}"
            }
            return "\(workspace)[\(label)]: \(tabs.joined(separator: " "))"
        }
        .joined(separator: " | ")
    }

    private func layout(ofTab tabID: String) -> [String: Any]? {
        layouts.first { $0["tab_id"] as? String == tabID }
    }
}

// MARK: - Comparing two snapshots

extension HerdrSnapshotJSON {
    /// Keys whose values move with nothing having touched the session:
    /// a pane's `revision` advances with its terminal's own output, `scroll`
    /// follows what that output pushes off the top, and `terminal_id` is
    /// minted fresh for every pane a reseed builds. Read, they would call an
    /// untouched session changed within a second and a reseeded one changed
    /// forever.
    ///
    /// Anything else that turns out to move on its own belongs here too, and
    /// `difference(from:)` names the exact path that moved so the next one is
    /// identified rather than guessed at.
    static let selfMovingKeys: Set<String> = ["revision", "scroll", "terminal_id"]

    func isStructurallyEqual(to other: HerdrSnapshotJSON) -> Bool {
        difference(from: other) == nil
    }

    /// The first place two snapshots disagree, as a path plus both values, or
    /// nil when they describe the same arrangement. A description rather than
    /// a bool because the case that needs this is asserting that NOTHING
    /// changed, and the only useful failure names what did.
    func difference(from other: HerdrSnapshotJSON) -> String? {
        Self.difference(raw, other.raw, at: "snapshot")
    }

    private static func difference(_ lhs: Any, _ rhs: Any, at path: String) -> String? {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            let keys = Set(left.keys).union(right.keys).subtracting(selfMovingKeys)
            for key in keys.sorted() {
                let here = "\(path).\(key)"
                switch (left[key], right[key]) {
                case (.none, .none):
                    continue
                case (.some(let mine), .some(let theirs)):
                    if let found = difference(mine, theirs, at: here) { return found }
                case (.some(let mine), .none):
                    return "\(here): \(describe(mine)) on the first, absent on the second"
                case (.none, .some(let theirs)):
                    return "\(here): absent on the first, \(describe(theirs)) on the second"
                }
            }
            return nil
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            if left.count != right.count {
                return "\(path): \(left.count) entries on the first, \(right.count) on the second"
            }
            for (index, pair) in zip(left, right).enumerated() {
                if let found = difference(pair.0, pair.1, at: "\(path)[\(index)\(identity(of: pair.0))]") {
                    return found
                }
            }
            return nil
        }
        if let left = lhs as? NSObject, let right = rhs as? NSObject, left.isEqual(right) {
            return nil
        }
        return "\(path): \(describe(lhs)) on the first, \(describe(rhs)) on the second"
    }

    /// An array entry named by whatever id it carries, so a path reads
    /// `panes[2 w1:p3].cwd` rather than `panes[2].cwd`.
    private static func identity(of entry: Any) -> String {
        guard let object = entry as? [String: Any] else { return "" }
        for key in ["pane_id", "tab_id", "workspace_id", "id"] {
            if let value = object[key] as? String { return " \(value)" }
        }
        return ""
    }

    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if let dictionary = value as? [String: Any] { return "an object of \(dictionary.count) keys" }
        if let array = value as? [Any] { return "a list of \(array.count)" }
        return "\(value)"
    }
}
