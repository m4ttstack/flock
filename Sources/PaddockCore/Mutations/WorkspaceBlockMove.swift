import Foundation

/// herdr's `workspace.move_block` as a pure function over an order. The
/// planner, the executor's inverse and the store's prediction all read the
/// result through here, so none of them can drift from
/// `move_workspace_block` in herdr's `actions.rs`.
public enum WorkspaceBlockMove {
    /// The order herdr leaves behind, or nil for a request herdr rejects: an
    /// empty or duplicated block, an id absent from `items`, or `before`
    /// inside the block. The block lands in the order it is LISTED, not the
    /// order its members had, because herdr splices `workspace_ids` verbatim.
    public static func apply<Item>(
        block: [WorkspaceID], before: WorkspaceID?, to items: [Item], id: (Item) -> WorkspaceID
    ) -> [Item]? {
        let members = Set(block)
        guard !block.isEmpty, members.count == block.count else { return nil }
        var byID: [WorkspaceID: Item] = [:]
        for item in items {
            byID[id(item)] = item
        }
        guard block.allSatisfy({ byID[$0] != nil }) else { return nil }
        if let before {
            guard !members.contains(before), byID[before] != nil else { return nil }
        }
        var result = items.filter { !members.contains(id($0)) }
        let insertAt = before.flatMap { anchor in result.firstIndex { id($0) == anchor } } ?? result.count
        result.insert(contentsOf: block.compactMap { byID[$0] }, at: insertAt)
        return result
    }

    public static func apply(block: [WorkspaceID], before: WorkspaceID?, to order: [WorkspaceID]) -> [WorkspaceID]? {
        apply(block: block, before: before, to: order, id: { $0 })
    }

    /// The `before` anchor that drops `block` into the gap `insertIndex`
    /// counts in `order`: the first workspace at or past that gap that is not
    /// itself moving, or nil for the end. herdr rejects an anchor inside the
    /// block, and a gap between two members means the same drop as the next
    /// unmoved workspace after them.
    public static func anchor(forInsertIndex insertIndex: Int, block: [WorkspaceID], order: [WorkspaceID]) -> WorkspaceID? {
        let members = Set(block)
        let start = min(max(insertIndex, 0), order.count)
        return order[start...].first { !members.contains($0) }
    }

    /// The moves that put `prior` back exactly after `block` moved before
    /// `before`. A block can only land contiguously, so a selection that was
    /// scattered through `prior` needs one move per run it occupied there,
    /// each anchored before the unmoved workspace that followed that run.
    /// Unmoved workspaces keep their relative order through any block move,
    /// so those anchors hold whichever order the runs replay in. A run
    /// already back in place is dropped, since herdr emits nothing for a
    /// move that changes nothing. Empty when the forward move is one herdr
    /// rejects.
    public static func inverse(
        block: [WorkspaceID], before: WorkspaceID?, prior: [WorkspaceID]
    ) -> [(block: [WorkspaceID], before: WorkspaceID?)] {
        guard var current = apply(block: block, before: before, to: prior) else { return [] }
        let members = Set(block)
        var runs: [(block: [WorkspaceID], before: WorkspaceID?)] = []
        var run: [WorkspaceID] = []
        for id in prior {
            if members.contains(id) {
                run.append(id)
            } else if !run.isEmpty {
                runs.append((run, id))
                run = []
            }
        }
        if !run.isEmpty {
            runs.append((run, nil))
        }

        var moves: [(block: [WorkspaceID], before: WorkspaceID?)] = []
        for candidate in runs {
            guard let next = apply(block: candidate.block, before: candidate.before, to: current), next != current else { continue }
            moves.append(candidate)
            current = next
        }
        return moves
    }
}
