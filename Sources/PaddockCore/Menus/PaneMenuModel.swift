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
/// on a submenu-parent row, which a real menu never invokes directly.
public struct PaneMenuEntry: Equatable, Sendable {
    public let label: String
    public let action: PaneMenuAction?
    public let accessibilityIdentifier: String
    public let enabled: Bool
    public let submenu: [PaneMenuEntry]?

    public init(
        label: String, action: PaneMenuAction?, accessibilityIdentifier: String,
        enabled: Bool = true, submenu: [PaneMenuEntry]? = nil
    ) {
        self.label = label
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
        self.enabled = enabled
        self.submenu = submenu
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
/// Split Down; Zoom; Close Pane. Labels are title case, macOS menu
/// convention, against herdr's sentence case; the strings are paired in
/// PARITY.md so the item set still diffs row for row.
///
/// Two rows differ from herdr deliberately. "Move to..." is paddock's own,
/// the spec's keyboard/accessibility parity path for every drag outcome, and
/// it sits between Zoom and Close Pane so every row paddock shares with herdr
/// keeps herdr's relative order. herdr's right-click passthrough toggle is
/// absent: paddock decides the disposition per click (plain goes to the pane
/// app whenever it is listening, Option always opens this menu), so there is
/// no per-pane mode for a row to flip.
public enum PaneMenuModel {
    public static func entries(for pane: PaneID, model: SessionModel, focusedPane: PaneID?) -> [PaneMenuEntry] {
        var entries: [PaneMenuEntry] = [PaneMenuEntry(
            label: "Rename Pane", action: .renamePane, accessibilityIdentifier: "paddock.pane.menu.rename"
        )]

        if model.panes[pane]?.label != nil {
            entries.append(PaneMenuEntry(
                label: "Clear Pane Name", action: .clearPaneName, accessibilityIdentifier: "paddock.pane.menu.clearName"
            ))
        }

        if case let .paneInterior(target)? = MoveToMenu.swapTarget(for: pane, focusedPane: focusedPane, model: model) {
            entries.append(PaneMenuEntry(
                label: "Swap with Focused Pane",
                action: .swapWithFocused(target),
                accessibilityIdentifier: "paddock.pane.menu.swap"
            ))
        }

        entries.append(PaneMenuEntry(
            label: "Split Right", action: .splitRight, accessibilityIdentifier: "paddock.pane.menu.splitRight"
        ))
        entries.append(PaneMenuEntry(
            label: "Split Down", action: .splitDown, accessibilityIdentifier: "paddock.pane.menu.splitDown"
        ))
        entries.append(PaneMenuEntry(
            label: "Zoom", action: .zoom, accessibilityIdentifier: "paddock.pane.menu.zoom"
        ))

        let moveToEntries = MoveToMenu.entries(for: pane, model: model).map { entry in
            PaneMenuEntry(label: entry.label, action: .moveTo(entry.target), accessibilityIdentifier: entry.accessibilityIdentifier)
        }
        entries.append(PaneMenuEntry(
            label: "Move to...", action: nil, accessibilityIdentifier: "paddock.pane.menu.moveTo",
            enabled: !moveToEntries.isEmpty, submenu: moveToEntries
        ))

        entries.append(PaneMenuEntry(
            label: "Close Pane", action: .closePane, accessibilityIdentifier: "paddock.pane.menu.closePane"
        ))

        return entries
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
