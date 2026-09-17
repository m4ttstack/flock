import Foundation

extension HerdrClient {
    /// Encodes `op` to its exact wire method + params and decodes the
    /// pieces later ops need. Every id is sent explicit (never omitted to
    /// lean on herdr's focused-pane fallback) except `movePaneToTab`'s
    /// `target`, whose nil is itself the explicit "let herdr pick the
    /// destination tab's focused pane" signal for tab-thumbnail drops.
    public func perform(_ op: PrimitiveOp) async throws -> OpResult {
        do {
            switch op {
            case let .movePaneToTab(pane, tab, target, split, ratio):
                let destination = PaneMoveParamsWire.Destination.tab(
                    tabID: tab.rawValue, targetPaneID: target?.rawValue, split: split, ratio: ratio
                )
                let wrapper: PaneMoveWrapper = try await request(
                    "pane.move", PaneMoveParamsWire(paneID: pane.rawValue, destination: destination), as: PaneMoveWrapper.self
                )
                return try Self.opResult(fromPaneMove: wrapper.moveResult)

            case let .movePaneToNewTab(pane, workspace, label):
                let destination = PaneMoveParamsWire.Destination.newTab(workspaceID: workspace.rawValue, label: label)
                let wrapper: PaneMoveWrapper = try await request(
                    "pane.move", PaneMoveParamsWire(paneID: pane.rawValue, destination: destination), as: PaneMoveWrapper.self
                )
                return try Self.opResult(fromPaneMove: wrapper.moveResult)

            case let .movePaneToNewWorkspace(pane, label, tabLabel):
                let destination = PaneMoveParamsWire.Destination.newWorkspace(label: label, tabLabel: tabLabel)
                let wrapper: PaneMoveWrapper = try await request(
                    "pane.move", PaneMoveParamsWire(paneID: pane.rawValue, destination: destination), as: PaneMoveWrapper.self
                )
                return try Self.opResult(fromPaneMove: wrapper.moveResult)

            case let .swapPanes(source, target):
                let wrapper: PaneSwapWrapper = try await request(
                    "pane.swap", PaneSwapParamsWire(sourcePaneID: source.rawValue, targetPaneID: target.rawValue), as: PaneSwapWrapper.self
                )
                if let reason = wrapper.swap.reason {
                    throw Self.mapCode(reason, message: "pane swap rejected: \(reason)")
                }
                return OpResult()

            case let .setSplitRatio(tab, path, ratio):
                _ = try await request(
                    "layout.set_split_ratio", LayoutSetSplitRatioParamsWire(tabID: tab.rawValue, path: path, ratio: ratio), as: DiscardedResult.self
                )
                return OpResult()

            case let .moveTab(tab, insertIndex):
                _ = try await request(
                    "tab.move", TabMoveParamsWire(tabID: tab.rawValue, insertIndex: insertIndex), as: DiscardedResult.self
                )
                return OpResult()

            case let .moveWorkspace(workspace, insertIndex):
                _ = try await request(
                    "workspace.move", WorkspaceMoveParamsWire(workspaceID: workspace.rawValue, insertIndex: insertIndex), as: DiscardedResult.self
                )
                return OpResult()

            case let .moveWorkspaceBlock(block, before):
                _ = try await request(
                    "workspace.move_block",
                    WorkspaceMoveBlockParamsWire(workspaceIDs: block.map(\.rawValue), beforeWorkspaceID: before?.rawValue),
                    as: DiscardedResult.self
                )
                return OpResult()

            case let .renamePane(pane, label):
                _ = try await request(
                    "pane.rename", PaneRenameParamsWire(paneID: pane.rawValue, label: label), as: DiscardedResult.self
                )
                return OpResult()

            case let .renameTab(tab, label):
                _ = try await request(
                    "tab.rename", TabRenameParamsWire(tabID: tab.rawValue, label: label), as: DiscardedResult.self
                )
                return OpResult()

            case let .renameWorkspace(workspace, label):
                _ = try await request(
                    "workspace.rename", WorkspaceRenameParamsWire(workspaceID: workspace.rawValue, label: label), as: DiscardedResult.self
                )
                return OpResult()

            case let .closePane(pane):
                _ = try await request("pane.close", PaneTargetWire(paneID: pane.rawValue), as: DiscardedResult.self)
                return OpResult()

            case let .closeTab(tab):
                _ = try await request("tab.close", TabTargetWire(tabID: tab.rawValue), as: DiscardedResult.self)
                return OpResult()

            case let .closeWorkspace(workspace, closeGroup):
                _ = try await request(
                    "workspace.close", WorkspaceCloseParamsWire(workspaceID: workspace.rawValue, closeGroup: closeGroup), as: DiscardedResult.self
                )
                return OpResult()

            case let .zoom(pane, mode):
                _ = try await request("pane.zoom", PaneZoomParamsWire(paneID: pane.rawValue, mode: mode), as: DiscardedResult.self)
                return OpResult()

            case let .focusPane(pane):
                _ = try await request("pane.focus", PaneTargetWire(paneID: pane.rawValue), as: DiscardedResult.self)
                return OpResult()

            case let .focusTab(tab):
                _ = try await request("tab.focus", TabTargetWire(tabID: tab.rawValue), as: DiscardedResult.self)
                return OpResult()

            case let .focusWorkspace(workspace):
                _ = try await request("workspace.focus", WorkspaceTargetWire(workspaceID: workspace.rawValue), as: DiscardedResult.self)
                return OpResult()
            }
        } catch let error as HerdrOpError {
            throw error
        } catch HerdrClientError.server(let code, let message) {
            throw Self.mapCode(code, message: message)
        }
    }

    private static func opResult(fromPaneMove result: PaneMoveResultWire) throws -> OpResult {
        if let reason = result.reason {
            throw Self.mapCode(reason, message: "pane move rejected: \(reason)")
        }
        return OpResult(
            movedPaneNewID: result.pane.paneID,
            createdTabID: result.createdTab?.tabID,
            createdWorkspaceID: result.createdWorkspace?.workspaceID
        )
    }

    /// Maps both a genuine `ErrorResponse.code` and a success response's
    /// `reason` field to the same typed error, so callers branch on one
    /// shape regardless of which the wire actually used for a given verb.
    private static func mapCode(_ code: String, message: String) -> HerdrOpError {
        switch code {
        case "same_tab": return .sameTab
        case "cross_tab": return .crossTab
        case "zoomed_tab": return .zoomedTab
        case "workspace_group_close_required": return .workspaceGroupCloseRequired
        default: return .other(code: code, message: message)
        }
    }
}

// MARK: - Wire params

/// `pane.move` (src/api/schema/panes.rs `PaneMoveParams`): `pane_id` plus a
/// `type`-tagged `destination` union (`PaneMoveDestination`).
private struct PaneMoveParamsWire: Encodable, Sendable {
    let paneID: String
    let destination: Destination

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case destination
    }

    enum Destination: Encodable, Sendable {
        case tab(tabID: String, targetPaneID: String?, split: SplitDirection, ratio: Double?)
        case newTab(workspaceID: String?, label: String?)
        case newWorkspace(label: String?, tabLabel: String?)

        private enum CodingKeys: String, CodingKey {
            case type
            case tabID = "tab_id"
            case targetPaneID = "target_pane_id"
            case split, ratio
            case workspaceID = "workspace_id"
            case label
            case tabLabel = "tab_label"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .tab(tabID, targetPaneID, split, ratio):
                try container.encode("tab", forKey: .type)
                try container.encode(tabID, forKey: .tabID)
                try container.encodeIfPresent(targetPaneID, forKey: .targetPaneID)
                try container.encode(split, forKey: .split)
                try container.encodeIfPresent(ratio, forKey: .ratio)
            case let .newTab(workspaceID, label):
                try container.encode("new_tab", forKey: .type)
                try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
                try container.encodeIfPresent(label, forKey: .label)
            case let .newWorkspace(label, tabLabel):
                try container.encode("new_workspace", forKey: .type)
                try container.encodeIfPresent(label, forKey: .label)
                try container.encodeIfPresent(tabLabel, forKey: .tabLabel)
            }
        }
    }
}

/// `pane.swap` (`PaneSwapParams`): the explicit-pair form, never the
/// direction form (flock always names both panes).
private struct PaneSwapParamsWire: Encodable, Sendable {
    let sourcePaneID: String
    let targetPaneID: String

    enum CodingKeys: String, CodingKey {
        case sourcePaneID = "source_pane_id"
        case targetPaneID = "target_pane_id"
    }
}

/// `layout.set_split_ratio` (`LayoutSetSplitRatioParams`), always by `tab_id`
/// (the alternative `pane_id` form is unused: flock always knows the tab).
private struct LayoutSetSplitRatioParamsWire: Encodable, Sendable {
    let tabID: String
    let path: [Bool]
    let ratio: Double

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case path, ratio
    }
}

/// `tab.move` (`TabMoveParams`).
private struct TabMoveParamsWire: Encodable, Sendable {
    let tabID: String
    let insertIndex: Int

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case insertIndex = "insert_index"
    }
}

/// `workspace.move` (`WorkspaceMoveParams`).
private struct WorkspaceMoveParamsWire: Encodable, Sendable {
    let workspaceID: String
    let insertIndex: Int

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case insertIndex = "insert_index"
    }
}

/// `workspace.move_block` (`WorkspaceMoveBlockParams`). herdr defaults an
/// absent `before_workspace_id` to the end, so nil is omitted, never null.
private struct WorkspaceMoveBlockParamsWire: Encodable, Sendable {
    let workspaceIDs: [String]
    let beforeWorkspaceID: String?

    enum CodingKeys: String, CodingKey {
        case workspaceIDs = "workspace_ids"
        case beforeWorkspaceID = "before_workspace_id"
    }
}

/// `pane.rename` (`PaneRenameParams`): `label: null` clears it.
private struct PaneRenameParamsWire: Encodable, Sendable {
    let paneID: String
    let label: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case label
    }
}

/// `tab.rename` (`TabRenameParams`): `label` is required, unlike pane rename.
private struct TabRenameParamsWire: Encodable, Sendable {
    let tabID: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case label
    }
}

/// `workspace.rename` (`WorkspaceRenameParams`): `label` is required.
private struct WorkspaceRenameParamsWire: Encodable, Sendable {
    let workspaceID: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

/// `workspace.close` (`WorkspaceCloseParams`).
private struct WorkspaceCloseParamsWire: Encodable, Sendable {
    let workspaceID: String
    let closeGroup: Bool

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case closeGroup = "close_group"
    }
}

/// `pane.zoom` (`PaneZoomParams`); `mode` encodes as its raw wire string.
private struct PaneZoomParamsWire: Encodable, Sendable {
    let paneID: String
    let mode: ZoomMode

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case mode
    }
}

/// `pane.focus` / `pane.close` (`PaneTarget`).
private struct PaneTargetWire: Encodable, Sendable {
    let paneID: String
    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
}

/// `tab.focus` / `tab.close` (`TabTarget`).
private struct TabTargetWire: Encodable, Sendable {
    let tabID: String
    enum CodingKeys: String, CodingKey { case tabID = "tab_id" }
}

/// `workspace.focus` (`WorkspaceTarget`).
private struct WorkspaceTargetWire: Encodable, Sendable {
    let workspaceID: String
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
}

// MARK: - Wire results

/// `result.move_result` (`ResponseResult::PaneMove`, `PaneMoveResult`).
/// `reason` (`same_tab` | `zoomed_tab`) is present only when `changed` is
/// false; `pane.pane_id` is the moved pane's id post-move, which differs
/// from the pane id that was passed in exactly when the move crossed a
/// workspace. `created_tab`/`created_workspace` are present only for the
/// destinations that create one.
private struct PaneMoveWrapper: Decodable, Sendable {
    let moveResult: PaneMoveResultWire
    enum CodingKeys: String, CodingKey { case moveResult = "move_result" }
}

private struct PaneMoveResultWire: Decodable, Sendable {
    struct PaneRef: Decodable, Sendable {
        let paneID: PaneID
        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }
    struct CreatedTabRef: Decodable, Sendable {
        let tabID: TabID
        enum CodingKeys: String, CodingKey { case tabID = "tab_id" }
    }
    struct CreatedWorkspaceRef: Decodable, Sendable {
        let workspaceID: WorkspaceID
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    }

    let reason: String?
    let pane: PaneRef
    let createdTab: CreatedTabRef?
    let createdWorkspace: CreatedWorkspaceRef?

    enum CodingKeys: String, CodingKey {
        case reason, pane
        case createdTab = "created_tab"
        case createdWorkspace = "created_workspace"
    }
}

/// `result.swap` (`ResponseResult::PaneSwap`, `PaneSwapResult`). `reason` is
/// present only when `changed` is false; flock's explicit-pair calls can
/// see `cross_tab` (the constraint), plus `same_pane`/`not_found`, all
/// folded into `HerdrOpError.other` unless named above.
private struct PaneSwapWrapper: Decodable, Sendable {
    struct SwapResult: Decodable, Sendable {
        let reason: String?
    }
    let swap: SwapResult
}

/// Shared for every verb whose response carries nothing flock needs
/// (rename/close/focus/zoom/reorder): a zero-property `Decodable` still
/// requires `result` to be present and decodable, so a malformed response
/// still fails loudly, without flock caring about the payload shape.
private struct DiscardedResult: Decodable, Sendable {}
