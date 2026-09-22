import Foundation

/// Turns one drag gesture into an ordered `OpPlan` against `model`, per the
/// design spec's verb table. Pure: no I/O, no herdr calls -- the executor is
/// the only thing that runs `ops` for real.
public func plan(dragging subject: DragSubject, onto target: DropTarget, model: SessionModel) -> Result<OpPlan, PlanError> {
    switch (subject, target) {
    case let (.pane(pane), .paneEdge(t, edge)):
        return planPaneEdge(pane: pane, target: t, edge: edge, model: model)

    case let (.pane(pane), .paneInterior(t)):
        return planPaneInterior(pane: pane, target: t, model: model)

    case let (.pane(pane), .tabThumbnail(tab)):
        return planPaneToTabThumbnail(pane: pane, tab: tab, model: model)

    case let (.pane(pane), .workspaceThumbnail(workspace)):
        return planPaneToNewTab(pane: pane, workspace: workspace, model: model)

    case let (.pane(pane), .newTab(workspace)):
        return planPaneToNewTab(pane: pane, workspace: workspace, model: model)

    case let (.pane(pane), .newWorkspace):
        return planPaneToNewWorkspace(pane: pane, model: model)

    case let (.tab(tab), .tabStrip(workspace, insertIndex)):
        return planTabReorder(tab: tab, workspace: workspace, insertIndex: insertIndex, model: model)

    case let (.tab(tab), .workspaceThumbnail(workspace)):
        return planTabMigration(tab: tab, workspace: workspace, model: model)

    // The rail's slot counts only the rows it drags, which leave herds out.
    case let (.workspace(workspace), .workspaceRail(insertIndex)):
        let modelIndex = HerdRail.modelInsertIndex(forRailIndex: insertIndex, in: model)
        return planWorkspaceReorder(workspace: workspace, insertIndex: modelIndex, model: model)

    case let (.workspaces(block), .workspaceRail(insertIndex)):
        let modelIndex = HerdRail.modelInsertIndex(forRailIndex: insertIndex, in: model)
        return planWorkspaceBlockReorder(block: block, insertIndex: modelIndex, model: model)

    case (_, .moreTabs):
        return .failure(.noOp)

    default:
        return .failure(.invalidCombination)
    }
}

// MARK: - pane subject

/// Left/top edges need the moved pane on the opposite side from where a
/// plain split lands it: a `movePaneToTab` split always places the target
/// as the first child and the moved-in pane as the second, at the node's
/// own ratio -- never the reverse -- so those two edges append a trailing
/// `swapPanes` to flip the pair.
private struct EdgeMapping {
    let direction: SplitDirection
    let needsSwap: Bool

    init(edge: Edge) {
        switch edge {
        case .left: direction = .right; needsSwap = true
        case .right: direction = .right; needsSwap = false
        case .top: direction = .down; needsSwap = true
        case .bottom: direction = .down; needsSwap = false
        }
    }
}

private func planPaneEdge(pane: PaneID, target t: PaneID, edge: Edge, model: SessionModel) -> Result<OpPlan, PlanError> {
    if pane == t {
        return .failure(.noOp)
    }
    guard let subjectRecord = model.panes[pane], let targetRecord = model.panes[t] else {
        return .failure(.invalidCombination)
    }
    let mapping = EdgeMapping(edge: edge)
    let sameTab = subjectRecord.tabID == targetRecord.tabID

    if sameTab {
        // herdr refuses same-tab `pane.move` outright (`same_tab`), so this
        // is always the bounce: park the pane in a fresh same-workspace tab,
        // then split it back in next to `t`. A same-workspace move keeps the
        // pane's own id, so no placeholder is needed for it; only the temp
        // tab's id is unknown until `movePaneToNewTab` runs.
        var ops: [PrimitiveOp] = [
            .movePaneToNewTab(pane, workspace: subjectRecord.workspaceID, label: nil),
            .movePaneToTab(pane, tab: targetRecord.tabID, target: t, split: mapping.direction, ratio: 0.5),
            .closeTab(TabID.planPlaceholder(createdByStep: 0)),
        ]
        if mapping.needsSwap {
            ops.append(.swapPanes(pane, t))
        }
        return .success(OpPlan(
            ops: ops,
            label: "Move pane",
            needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: targetRecord.tabID)
        ))
    }

    var ops: [PrimitiveOp] = [
        .movePaneToTab(pane, tab: targetRecord.tabID, target: t, split: mapping.direction, ratio: 0.5),
    ]
    if mapping.needsSwap {
        let crossesWorkspace = subjectRecord.workspaceID != targetRecord.workspaceID
        let movedID = crossesWorkspace ? PaneID.planPlaceholder(movedByStep: 0) : pane
        ops.append(.swapPanes(movedID, t))
    }
    return .success(OpPlan(
        ops: ops,
        label: "Move pane",
        needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: targetRecord.tabID)
    ))
}

private func planPaneInterior(pane: PaneID, target t: PaneID, model: SessionModel) -> Result<OpPlan, PlanError> {
    if pane == t {
        return .failure(.noOp)
    }
    guard let subjectRecord = model.panes[pane], let targetRecord = model.panes[t] else {
        return .failure(.invalidCombination)
    }
    if subjectRecord.tabID == targetRecord.tabID {
        return .success(OpPlan(
            ops: [.swapPanes(pane, t)],
            label: "Swap panes",
            needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: nil)
        ))
    }
    return .success(OpPlan(
        ops: [.movePaneToTab(pane, tab: targetRecord.tabID, target: t, split: .right, ratio: 0.5)],
        label: "Move pane into tab",
        needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: targetRecord.tabID)
    ))
}

private func planPaneToTabThumbnail(pane: PaneID, tab: TabID, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard let subjectRecord = model.panes[pane],
          model.tabs.values.contains(where: { $0.contains { $0.tabID == tab } }) else {
        return .failure(.invalidCombination)
    }
    // The pane is already in this tab, and herdr refuses a same-tab
    // `pane.move` outright (`same_tab`).
    guard subjectRecord.tabID != tab else {
        return .failure(.noOp)
    }
    return .success(OpPlan(
        ops: [.movePaneToTab(pane, tab: tab, target: nil, split: .right, ratio: 0.5)],
        label: "Move pane into tab",
        needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: tab)
    ))
}

private func planPaneToNewTab(pane: PaneID, workspace: WorkspaceID, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard let subjectRecord = model.panes[pane],
          model.workspaces.contains(where: { $0.workspaceID == workspace }) else {
        return .failure(.invalidCombination)
    }
    return .success(OpPlan(
        ops: [.movePaneToNewTab(pane, workspace: workspace, label: nil)],
        label: "Move pane to new tab",
        needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: nil)
    ))
}

private func planPaneToNewWorkspace(pane: PaneID, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard let subjectRecord = model.panes[pane] else {
        return .failure(.invalidCombination)
    }
    return .success(OpPlan(
        ops: [.movePaneToNewWorkspace(pane, label: nil, tabLabel: nil)],
        label: "Move pane to new workspace",
        needsUnzoom: unzoomList(model: model, source: subjectRecord.tabID, destination: nil)
    ))
}

// MARK: - tab subject

/// An insert index counts gaps, and the two gaps either side of a tab's own
/// slot both name the place it already has: `ReshuffleOffset.landedSlot` is
/// the one rule that says so, and it is the same rule the strip and the grid
/// slide their items by, so a preview that moves nothing and a plan that does
/// nothing cannot disagree.
private func planTabReorder(tab: TabID, workspace: WorkspaceID, insertIndex: Int, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard let index = model.tabs[workspace]?.firstIndex(where: { $0.tabID == tab }) else {
        return .failure(.invalidCombination)
    }
    guard ReshuffleOffset.landedSlot(forItemAt: index, draggingIndex: index, insertIndex: insertIndex) != index else {
        return .failure(.noOp)
    }
    return .success(OpPlan(
        ops: [.moveTab(tab, insertIndex: insertIndex)],
        label: "Move tab",
        needsUnzoom: unzoomList(model: model, source: tab, destination: nil)
    ))
}

/// Migrates every pane of `tab` into a new tab in `workspace`, replaying the
/// source tab's split shape via a sequence of single-pane splits.
///
/// Traversal contract: reconstruct `tab`'s split layout as a binary tree
/// (`SplitTree`, first child before second, matching herdr's own
/// left/top-then-right/bottom split-path polarity). Place the tree's
/// leftmost pane first via `movePaneToNewTab` -- it anchors the whole tree,
/// occupying the destination tab's entire area until the first split lands.
/// Then walk the tree pre-order over split nodes: at each split, bring in
/// that split's second child's own leftmost pane via `movePaneToTab`,
/// splitting off of the anchor that currently occupies this split's full
/// rect (`direction`/`ratio` straight from the tree), which divides that
/// anchor's region into exactly the split's two children. Recurse into the
/// first child with the same anchor (its region is now correct) and into
/// the second child with the just-moved pane as its new anchor. Every move
/// in this migration crosses into `workspace`, so every anchor after the
/// first is carried as a `PaneID.planPlaceholder`, never a literal id.
///
/// Every source pane must be moved individually: `pane.move` only ever
/// turns one existing single-pane region into two, so a subtree with more
/// than one leaf cannot be materialized in one op regardless of how deep it
/// nests in the source tree.
private func planTabMigration(tab: TabID, workspace: WorkspaceID, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard model.workspaces.contains(where: { $0.workspaceID == workspace }) else {
        return .failure(.invalidCombination)
    }
    // Already there. Replaying the shape into a fresh tab of the same
    // workspace would destroy and rebuild the tab for no move at all.
    guard model.tabs[workspace]?.contains(where: { $0.tabID == tab }) != true else {
        return .failure(.noOp)
    }
    guard let layout = model.layouts[tab], !layout.panes.isEmpty,
          let tree = SplitTree.build(from: layout) else {
        return .failure(.invalidCombination)
    }

    var ops: [PrimitiveOp] = [
        .movePaneToNewTab(tree.leftmostPaneID, workspace: workspace, label: carriedName(ofTab: tab, model: model)),
    ]
    let destinationTab = TabID.planPlaceholder(createdByStep: 0)
    let rootAnchor = PaneID.planPlaceholder(movedByStep: 0)
    materialize(tree, anchor: rootAnchor, destinationTab: destinationTab, ops: &ops)

    return .success(OpPlan(
        ops: ops,
        label: "Move tab to workspace",
        needsUnzoom: unzoomList(model: model, source: tab, destination: nil)
    ))
}

/// The name to ask a recreated tab to be born with, or nil to let herdr name
/// it. herdr reports a tab nobody has renamed as its own 1-based position, so
/// that string is a default rather than a name: sending it back would pin the
/// source position as a real name, and the destination can already hold a tab
/// sitting at that position. The comparison is against the position, never
/// `TabRecord.number`, which survives a closed tab and so drifts away from it.
///
/// Internal, not private: `MutationEngine` asks the same question when it
/// builds the inverse that recreates a migrated tab, and the two must answer
/// it identically or an undo renames what the forward move did not.
func carriedName(ofTab tab: TabID, model: SessionModel) -> String? {
    for tabs in model.tabs.values {
        guard let position = tabs.firstIndex(where: { $0.tabID == tab }) else { continue }
        let label = tabs[position].label
        return label == String(position + 1) ? nil : label
    }
    return nil
}

private func materialize(_ node: SplitTree, anchor: PaneID, destinationTab: TabID, ops: inout [PrimitiveOp]) {
    guard case let .split(direction, ratio, first, second) = node else { return }
    let secondPaneID = second.leftmostPaneID
    let thisStep = ops.count
    ops.append(.movePaneToTab(secondPaneID, tab: destinationTab, target: anchor, split: direction, ratio: ratio))
    let secondAnchor = PaneID.planPlaceholder(movedByStep: thisStep)
    materialize(first, anchor: anchor, destinationTab: destinationTab, ops: &ops)
    materialize(second, anchor: secondAnchor, destinationTab: destinationTab, ops: &ops)
}

// MARK: - workspace subject

private func planWorkspaceReorder(workspace: WorkspaceID, insertIndex: Int, model: SessionModel) -> Result<OpPlan, PlanError> {
    guard model.workspaces.contains(where: { $0.workspaceID == workspace }) else {
        return .failure(.invalidCombination)
    }
    return .success(OpPlan(ops: [.moveWorkspace(workspace, insertIndex: insertIndex)], label: "Move workspace", needsUnzoom: []))
}

/// The block is sent in rail order whatever order the selection arrived in:
/// herdr splices it as listed, and a block drag must never shuffle its own
/// members. A drop that leaves the order unchanged is a no-op here rather
/// than a call herdr would answer with no event to converge on.
private func planWorkspaceBlockReorder(block: [WorkspaceID], insertIndex: Int, model: SessionModel) -> Result<OpPlan, PlanError> {
    let order = model.workspaces.map(\.workspaceID)
    let members = Set(block)
    guard !block.isEmpty, members.count == block.count, members.isSubset(of: order) else {
        return .failure(.invalidCombination)
    }
    let inRailOrder = order.filter(members.contains)
    let before = WorkspaceBlockMove.anchor(forInsertIndex: insertIndex, block: inRailOrder, order: order)
    guard let result = WorkspaceBlockMove.apply(block: inRailOrder, before: before, to: order) else {
        return .failure(.invalidCombination)
    }
    guard result != order else { return .failure(.noOp) }
    return .success(OpPlan(ops: [.moveWorkspaceBlock(inRailOrder, before: before)], label: "Move workspaces", needsUnzoom: []))
}

// MARK: - shared

private func unzoomList(model: SessionModel, source: TabID?, destination: TabID?) -> [TabID] {
    var result: [TabID] = []
    if let source, model.layouts[source]?.zoomed == true {
        result.append(source)
    }
    if let destination, destination != source, model.layouts[destination]?.zoomed == true {
        result.append(destination)
    }
    return result
}

/// A tab's split layout reconstructed as a binary tree from
/// `LayoutSnapshot`'s flat `splits`/`panes` arrays. Internal (not
/// `private`): `MutationEngine` reuses this same reconstruction to rebuild
/// a migrated tab's original shape for its inverse, rather than duplicating
/// tree-building logic that must stay in lockstep with this one.
///
/// `SessionModel` -- unlike `SessionViewModel`'s `layoutExportCoordinator`,
/// which is outside FlockCore's pure model -- carries no `layout.export`
/// tree to read parent/child order from directly, so this is the rect-derived
/// fallback the design brief anticipates: nesting is derived by rect
/// containment, mirroring `CanvasGeometry`'s own fallback path. A split's
/// rect divides at its own direction/ratio into a first (left/top) and
/// second (right/bottom) child region; whichever split or pane's rect
/// exactly matches a child region is that child. A tree that cannot be
/// reconstructed this way (no split or pane rect matches some child region)
/// fails the plan rather than guessing at a shape.
indirect enum SplitTree {
    case pane(PaneID)
    case split(direction: SplitDirection, ratio: Double, first: SplitTree, second: SplitTree)

    /// The pane that occupies an entire subtree's region before that
    /// subtree has been split any further: reached by always descending
    /// into the first child, so it is the anchor a migration plan carries
    /// as the placeholder representing this subtree until it is subdivided.
    var leftmostPaneID: PaneID {
        switch self {
        case let .pane(id): return id
        case let .split(_, _, first, _): return first.leftmostPaneID
        }
    }

    static func build(from layout: LayoutSnapshot) -> SplitTree? {
        if layout.panes.count == 1 {
            return .pane(layout.panes[0].paneID)
        }
        guard let root = layout.splits.first(where: { $0.rect == layout.area }) else {
            return nil
        }
        return buildSubtree(from: root, splits: layout.splits, panes: layout.panes)
    }

    private static func buildSubtree(from split: SplitInfo, splits: [SplitInfo], panes: [PaneRect]) -> SplitTree? {
        let (firstRegion, secondRegion) = childRegions(of: split.rect, direction: split.direction, ratio: split.ratio)
        guard let first = node(for: firstRegion, splits: splits, panes: panes),
              let second = node(for: secondRegion, splits: splits, panes: panes) else {
            return nil
        }
        return .split(direction: split.direction, ratio: split.ratio, first: first, second: second)
    }

    private static func node(for rect: CellRect, splits: [SplitInfo], panes: [PaneRect]) -> SplitTree? {
        if let split = splits.first(where: { $0.rect == rect }) {
            return buildSubtree(from: split, splits: splits, panes: panes)
        }
        if let pane = panes.first(where: { $0.rect == rect }) {
            return .pane(pane.paneID)
        }
        return nil
    }

    /// Matches `CanvasGeometry`'s own child-region rounding exactly (integer
    /// cell grid, `.rounded()` on the first child's size) so the tree
    /// reconstructed here lines up with the same regions herdr's layout
    /// actually used. Internal, not private: a thumbnail previewing a pane
    /// landing in a tab divides a region by the same rule.
    static func childRegions(of rect: CellRect, direction: SplitDirection, ratio: Double) -> (first: CellRect, second: CellRect) {
        switch direction {
        case .right:
            let firstWidth = Int((Double(rect.width) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height)
            let second = CellRect(x: rect.x + firstWidth, y: rect.y, width: rect.width - firstWidth, height: rect.height)
            return (first, second)
        case .down:
            let firstHeight = Int((Double(rect.height) * ratio).rounded())
            let first = CellRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight)
            let second = CellRect(x: rect.x, y: rect.y + firstHeight, width: rect.width, height: rect.height - firstHeight)
            return (first, second)
        }
    }
}
