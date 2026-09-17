import AppKit
import FlockCore

/// Builds the real `NSMenu` a pane's right-click shows, from the same rows
/// `PaneMenuModel.entries` produces for the SwiftUI `.contextMenu` fallback
/// (`PaneCellView`'s card-mode branch) -- both read from `PaneMenuModel`, so
/// the two can never drift. Built fresh from the CURRENT model on every
/// right-click (never cached), so a click never shows a "Move to..."
/// submenu for a tab or workspace that has since gone away.
@MainActor
enum PaneMenuBuilder {
    static func menu(for paneID: PaneID, viewModel: SessionViewModel) -> NSMenu? {
        guard let model = viewModel.model else { return nil }
        let entries = PaneMenuModel.entries(for: paneID, model: model, focusedPane: viewModel.resolvedFocusedPaneID)
        let target = PaneMenuActionTarget(paneID: paneID, viewModel: viewModel)
        let menu = PaneContextMenu(actionTarget: target)
        for entry in entries {
            menu.addItem(makeMenuItem(for: entry, target: target))
        }
        return menu
    }

    private static func makeMenuItem(for entry: PaneMenuEntry, target: PaneMenuActionTarget) -> NSMenuItem {
        let menuItem = NSMenuItem(title: entry.label, action: nil, keyEquivalent: "")
        menuItem.identifier = NSUserInterfaceItemIdentifier(entry.accessibilityIdentifier)
        menuItem.setAccessibilityIdentifier(entry.accessibilityIdentifier)
        menuItem.isEnabled = entry.enabled

        if let submenuEntries = entry.submenu {
            let submenu = NSMenu(title: entry.label)
            for submenuEntry in submenuEntries {
                submenu.addItem(makeMenuItem(for: submenuEntry, target: target))
            }
            menuItem.submenu = submenu
        } else {
            menuItem.target = target
            menuItem.action = #selector(PaneMenuActionTarget.performMenuAction(_:))
            menuItem.representedObject = entry.action
        }
        return menuItem
    }
}

/// Retains the dispatch target for as long as the menu it built lives --
/// `NSMenuItem.target` does not retain, and `PaneMenuBuilder.menu(for:viewModel:)`
/// builds a fresh menu (and target) on every right-click, so without this the
/// target would be freed before AppKit ever shows the menu.
private final class PaneContextMenu: NSMenu {
    let actionTarget: PaneMenuActionTarget

    init(actionTarget: PaneMenuActionTarget) {
        self.actionTarget = actionTarget
        super.init(title: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The one `@objc` action every real menu item dispatches through --
/// `representedObject` carries which `PaneMenuAction` a given item is, so one
/// selector serves the whole menu rather than one per action.
@MainActor
private final class PaneMenuActionTarget: NSObject {
    let paneID: PaneID
    let viewModel: SessionViewModel

    init(paneID: PaneID, viewModel: SessionViewModel) {
        self.paneID = paneID
        self.viewModel = viewModel
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PaneMenuAction else { return }
        Task { [paneID, viewModel] in
            await action.perform(paneID: paneID, on: viewModel)
        }
    }
}
