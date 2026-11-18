import FlockCore
import SwiftUI

/// The close warning as a confirm card. A close made on the tab strip, from a
/// tab's close button or its menu, hangs the card from that tab; a pane's own
/// right-click menu pins it where the click was, opening toward the pane's
/// middle.
struct CloseWarningCard: ViewModifier {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(DragCoordinator.self) private var drag

    func body(content: Content) -> some View {
        content.modifier(ConfirmCardPresenter(
            theme: theme,
            item: viewModel.pendingClose,
            content: { pending in
                ConfirmCardContent(
                    action: pending.action,
                    name: pending.name,
                    nameSymbol: Self.symbol(for: pending.action),
                    message: (try? AttributedString(markdown: pending.message)) ?? AttributedString(pending.message),
                    suppression: pending.warnsOfAgents ? "Don't warn me next time" : nil,
                    confirmTitle: pending.confirmButtonTitle,
                    identifier: "flock.close"
                )
            },
            anchor: { pending, origin, proxy in
                guard case .pointer(let point, let onTitleBar) = origin else { return nil }
                switch pending.subject {
                case .tab(let tab):
                    guard onTitleBar else { return nil }
                    return frame(of: tab, in: proxy).map { .hang(below: $0) }
                case .pane(let pane):
                    let frame = frame(of: pane, in: proxy)
                    // The menu item can sit outside the pane; the card still
                    // pops from it, toward the pane's middle.
                    guard let point, let frame else { return nil }
                    return .pinned(point, within: frame)
                }
            },
            answer: { pending, answer in
                Task { await viewModel.answerClose(pending.subject, confirm: answer.confirmed, stopWarning: answer.suppressed) }
            }
        ))
    }

    /// What the name is the name of: the action names what really closes,
    /// which an escalated close has already widened past the subject.
    private static func symbol(for action: String) -> String {
        if action.hasPrefix("Close Workspace") { return "square.stack" }
        if action.hasPrefix("Close Tab") { return ChromeType.tabPaneGlyphName }
        return "terminal"
    }

    /// The pane's frame in the overlay's space, while the canvas shows it.
    private func frame(of pane: PaneID, in proxy: GeometryProxy) -> CGRect? {
        let origin = proxy.frame(in: DragSpace.coordinateSpace).origin
        return drag.canvas.paneFrames[pane]?.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// The tab's frame in the overlay's space, while the strip shows it.
    private func frame(of tab: TabID, in proxy: GeometryProxy) -> CGRect? {
        let origin = proxy.frame(in: DragSpace.coordinateSpace).origin
        return drag.tabFrames.first { $0.id == tab }?.frame.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}
