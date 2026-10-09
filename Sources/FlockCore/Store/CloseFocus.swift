import Foundation

/// The pane that takes focus when the focused pane closes: the one that
/// grows into the space it leaves, so the keyboard stays in the same tab.
public enum CloseFocus {
    /// The nearest pane of the closed pane's sibling subtree, or nil when
    /// the pane is its tab's only one. A tab whose layout cannot be rebuilt
    /// as a tree falls back to the pane before it in herdr's order.
    public static func successor(of pane: PaneID, model: SessionModel) -> PaneID? {
        guard let tab = model.panes[pane]?.tabID, let layout = model.layouts[tab] else { return nil }
        let others = layout.panes.map(\.paneID).filter { $0 != pane }
        guard !others.isEmpty else { return nil }
        if let tree = SplitTree.build(from: layout), let sibling = tree.nearestSibling(of: pane) {
            return sibling
        }
        let index = layout.panes.firstIndex { $0.paneID == pane } ?? 0
        return index > 0 ? layout.panes[index - 1].paneID : others.first
    }
}

extension SplitTree {
    var rightmostPaneID: PaneID {
        switch self {
        case let .pane(id): return id
        case let .split(_, _, _, second): return second.rightmostPaneID
        }
    }

    func contains(_ pane: PaneID) -> Bool {
        switch self {
        case let .pane(id): return id == pane
        case let .split(_, _, first, second): return first.contains(pane) || second.contains(pane)
        }
    }

    /// The pane on the far side of the divider that `pane` shares with its
    /// sibling, which is the pane drawn right against it.
    func nearestSibling(of pane: PaneID) -> PaneID? {
        guard case let .split(_, _, first, second) = self else { return nil }
        if case .pane(pane) = first { return second.leftmostPaneID }
        if case .pane(pane) = second { return first.rightmostPaneID }
        if first.contains(pane) { return first.nearestSibling(of: pane) }
        if second.contains(pane) { return second.nearestSibling(of: pane) }
        return nil
    }
}
