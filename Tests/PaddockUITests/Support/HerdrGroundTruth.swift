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
/// third flat list keyed by `tab_id`. Assuming the nested shape is what made
/// spike 5's first tab count report no change over a move that had in fact
/// landed.
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

    private func layout(ofTab tabID: String) -> [String: Any]? {
        layouts.first { $0["tab_id"] as? String == tabID }
    }
}
