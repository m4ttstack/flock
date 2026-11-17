import FlockCore
import SwiftUI

/// The close warning as a confirm card. A close made on the tab strip, from a
/// tab's close button or its menu, hangs the card from that tab.
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
                    message: (try? AttributedString(markdown: pending.message)) ?? AttributedString(pending.message),
                    suppression: pending.warnsOfAgents ? "Don't warn me next time" : nil,
                    confirmTitle: pending.confirmButtonTitle,
                    identifier: "flock.close"
                )
            },
            anchor: { pending, origin, proxy in
                guard case .tab(let tab) = pending.subject, case .pointer(_, pressOnTitleBar: true) = origin else { return nil }
                return frame(of: tab, in: proxy)
            },
            answer: { pending, answer in
                Task { await viewModel.answerClose(pending.subject, confirm: answer.confirmed, stopWarning: answer.suppressed) }
            }
        ))
    }

    /// The tab's frame in the overlay's space, while the strip shows it.
    private func frame(of tab: TabID, in proxy: GeometryProxy) -> CGRect? {
        let origin = proxy.frame(in: DragSpace.coordinateSpace).origin
        return drag.tabFrames.first { $0.id == tab }?.frame.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}
