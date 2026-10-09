import Foundation

/// One command a pane context-menu row can run. `swapWithFocused` carries
/// the FOCUSED pane's id (the target of the swap), not the menu's own pane --
/// the owning pane is supplied separately at dispatch time by whichever
/// caller built the row (`PaneMenuModel.entries(for:model:focusedPane:)`
/// already knows it).
public enum PaneMenuAction: Equatable, Sendable {
    case renamePane
    case clearPaneName
    case swapWithFocused(PaneID)
    case splitRight
    case splitDown
    case zoom
    case moveTo(DropTarget)
    case closePane
}

/// One row of the pane context menu. `submenu` is non-nil only on the
/// "Move to..." row; every other row leaves it `nil`. `action` is `nil` only
/// on a submenu-parent row, a header or a separator, which a real menu never
/// invokes directly.
public struct PaneMenuEntry: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case item
        /// Names the group of rows below it.
        case header
        case separator
    }

    public let label: String
    public let action: PaneMenuAction?
    public let accessibilityIdentifier: String
    public let enabled: Bool
    public let submenu: [PaneMenuEntry]?
    public let role: Role
    /// The `WorkspaceIdentityStore` key whose symbol the row shows.
    public let identityKey: String?

    public init(
        label: String, action: PaneMenuAction?, accessibilityIdentifier: String,
        enabled: Bool = true, submenu: [PaneMenuEntry]? = nil, role: Role = .item, identityKey: String? = nil
    ) {
        self.label = label
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
        self.enabled = enabled
        self.submenu = submenu
        self.role = role
        self.identityKey = identityKey
    }
}

/// Pure model for the pane right-click menu -- no view, no `NSMenu`, no
/// herdr call, just `SessionModel` in and rows out. Both the real `NSMenu`
/// (`PaneMenuBuilder`, the ghostty-attached branch) and the SwiftUI
/// `.contextMenu` fallback (`PaneCellView`'s card-mode branch, for a pane
/// with no ghostty view yet) render from the SAME rows this produces, so the
/// two can never drift.
///
/// Order and item set mirror herdr's own `ClientContextMenuTarget::Pane`
/// (`src/client/shell/context_menu.rs`, tracked as a row in
/// `docs/design/PARITY.md`): Rename Pane; Clear Pane Name only while the pane
/// carries a manual label; Swap with Focused Pane only when herdr's focus is
/// on another pane of the SAME tab (`MoveToMenu.swapTarget`); Split Right;
/// Split Down; Zoom, which reads Unzoom while the tab is zoomed; Close Pane.
/// Labels are title case, macOS menu convention, against herdr's sentence
/// case; the strings are paired in PARITY.md so the item set still diffs row
/// for row.
///
/// Two rows differ from herdr deliberately. "Move to..." is flock's own,
/// the spec's keyboard/accessibility parity path for every drag outcome, and
/// it sits between Zoom and Close Pane so every row flock shares with herdr
/// keeps herdr's relative order. herdr's right-click passthrough toggle is
/// absent: flock decides the disposition per click (plain goes to the pane
/// app whenever it is listening, Option always opens this menu), so there is
/// no per-pane mode for a row to flip.
public enum PaneMenuModel {
    /// `solo` is a pane shown alone, away from its tab: only the rows that
    /// neither change the tab around it nor move herdr's focus.
    public static func entries(
        for pane: PaneID, model: SessionModel, focusedPane: PaneID?, solo: Bool, oneTitle: Bool = false,
        sections: RailSections? = nil
    ) -> [PaneMenuEntry] {
        let all = entries(for: pane, model: model, focusedPane: focusedPane, oneTitle: oneTitle, sections: sections)
        guard solo else { return all }
        return all.filter { [.renamePane, .clearPaneName, .closePane].contains($0.action) }
    }

    /// With `oneTitle` on, Rename Pane renames a one-pane tab
    /// (`PaneNaming.renameTarget`), and Clear Pane Name is left out there: it
    /// would clear a label nothing draws.
    public static func entries(
        for pane: PaneID, model: SessionModel, focusedPane: PaneID?, oneTitle: Bool = false, sections: RailSections? = nil
    ) -> [PaneMenuEntry] {
        var entries: [PaneMenuEntry] = [PaneMenuEntry(
            label: "Rename Pane", action: .renamePane, accessibilityIdentifier: "flock.pane.menu.rename"
        )]

        if let record = model.panes[pane], record.label != nil,
           PaneNaming.titleTab(of: record, model: model, oneTitle: oneTitle) == nil {
            entries.append(PaneMenuEntry(
                label: "Clear Pane Name", action: .clearPaneName, accessibilityIdentifier: "flock.pane.menu.clearName"
            ))
        }

        if case let .paneInterior(target)? = MoveToMenu.swapTarget(for: pane, focusedPane: focusedPane, model: model) {
            entries.append(PaneMenuEntry(
                label: "Swap with Focused Pane",
                action: .swapWithFocused(target),
                accessibilityIdentifier: "flock.pane.menu.swap"
            ))
        }

        entries.append(PaneMenuEntry(
            label: "Split Right", action: .splitRight, accessibilityIdentifier: "flock.pane.menu.splitRight"
        ))
        entries.append(PaneMenuEntry(
            label: "Split Down", action: .splitDown, accessibilityIdentifier: "flock.pane.menu.splitDown"
        ))
        entries.append(PaneMenuEntry(
            label: isZoomed(pane, model: model) ? "Unzoom" : "Zoom", action: .zoom, accessibilityIdentifier: "flock.pane.menu.zoom"
        ))

        let moveToEntries = moveToRows(MoveToMenu.entries(for: pane, model: model, sections: sections))
        entries.append(PaneMenuEntry(
            label: "Move to...", action: nil, accessibilityIdentifier: "flock.pane.menu.moveTo",
            enabled: !moveToEntries.isEmpty, submenu: moveToEntries
        ))

        entries.append(PaneMenuEntry(
            label: "Close Pane", action: .closePane, accessibilityIdentifier: "flock.pane.menu.closePane"
        ))

        return entries
    }

    /// Each group of rows under a header naming it; the create rows after a
    /// separator.
    static func moveToRows(_ entries: [MoveToEntry]) -> [PaneMenuEntry] {
        var rows: [PaneMenuEntry] = []
        var group: MoveToEntry.Group?
        for entry in entries {
            if entry.group != group {
                switch entry.group {
                case .tabs:
                    rows.append(PaneMenuEntry(
                        label: "Tabs", action: nil, accessibilityIdentifier: "flock.pane.menu.moveTo.header.tabs", role: .header
                    ))
                case .workspaces:
                    rows.append(PaneMenuEntry(
                        label: "Workspaces", action: nil, accessibilityIdentifier: "flock.pane.menu.moveTo.header.workspaces", role: .header
                    ))
                case .create where group != nil:
                    rows.append(PaneMenuEntry(
                        label: "", action: nil, accessibilityIdentifier: "flock.pane.menu.moveTo.separator", role: .separator
                    ))
                case .create:
                    break
                }
                group = entry.group
            }
            rows.append(PaneMenuEntry(
                label: entry.label, action: .moveTo(entry.target), accessibilityIdentifier: entry.accessibilityIdentifier,
                identityKey: entry.identityKey
            ))
        }
        return rows
    }

    /// herdr zooms a tab, not a pane, so every pane of a zoomed tab reads as
    /// zoomed and its toggle unzooms.
    public static func isZoomed(_ pane: PaneID, model: SessionModel) -> Bool {
        guard let tab = model.panes[pane]?.tabID else { return false }
        return model.layouts[tab]?.zoomed == true
    }
}

extension PaneMenuAction {
    /// The one dispatch both renderers share: a real `NSMenu`'s target/action
    /// (`PaneMenuBuilder`) and the SwiftUI `.contextMenu` fallback
    /// (`PaneCellView`) both end every row in this same call, so the two
    /// menus can never wire a row to different `SessionViewModel` behavior.
    @MainActor
    public func perform(paneID: PaneID, on viewModel: SessionViewModel) async {
        switch self {
        case .renamePane:
            viewModel.beginRename(.pane(paneID))
        case .clearPaneName:
            await viewModel.clearPaneName(paneID)
        case .zoom:
            await viewModel.toggleZoom(paneID)
        case .swapWithFocused(let focusedPane):
            await viewModel.perform(subject: .pane(paneID), target: .paneInterior(focusedPane))
        case .splitRight:
            await viewModel.splitRight(from: paneID)
        case .splitDown:
            await viewModel.splitDown(from: paneID)
        case .moveTo(let target):
            await viewModel.perform(subject: .pane(paneID), target: target)
        case .closePane:
            await viewModel.closePane(paneID)
        }
    }
}
