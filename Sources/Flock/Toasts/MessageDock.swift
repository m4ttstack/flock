import FlockCore
import SwiftUI

/// Every window-scope message in one place: the notice (a `ToastCenter`
/// toast with no pane) over the attention cards. In the rail it is part of the
/// rail's own layout, under the lists and outside their scroll view, so the
/// lists give it room and nothing is drawn over a pane or a row. Over the grid
/// there is no rail, so there it floats in the corner the rail would occupy.
///
/// Empty, it draws nothing, rule included, so the lists get their full height
/// back.
///
/// Anchored at its foot, which is why the notice and the newest card go at the
/// top: anything arriving or leaving there moves only the dock's top edge,
/// never a card the pointer may already be on.
///
/// Its tallest state is bounded without a measurement: one notice of at most
/// `Dock.noticeLineLimit` lines, `AttentionToastStack.maximumVisible` cards
/// and the "more" pill.
///
/// A pane-scoped toast (the copied whisper) is not drawn here; its own pane
/// cell draws it (see `PaneCellView`).
struct MessageDock: View {
    enum Placement {
        case rail
        case overGrid
    }

    let theme: Theme
    let viewModel: SessionViewModel
    let placement: Placement

    @Environment(ToastCenter.self) private var toastCenter

    private var notice: ToastCenter.Toast? {
        guard let toast = toastCenter.current, toast.paneID == nil else { return nil }
        return toast
    }

    private var isFloating: Bool { placement == .overGrid }

    var body: some View {
        if notice != nil || !viewModel.attentionToasts.isEmpty {
            VStack(spacing: 0) {
                if placement == .rail {
                    Rectangle()
                        .fill(theme.rule)
                        .frame(height: ChromeMetrics.ruleWidth)
                }
                VStack(alignment: .leading, spacing: ChromeMetrics.Dock.itemSpacing) {
                    if let notice {
                        NoticeCard(theme: theme, toast: notice, isFloating: isFloating)
                            .id(notice.id)
                            .transition(.opacity)
                    }
                    AttentionToastStackView(theme: theme, viewModel: viewModel, isFloating: isFloating)
                }
                .padding(.top, isFloating ? 0 : ChromeMetrics.Dock.ruleToFirstItem)
                .padding(.bottom, ChromeMetrics.Dock.bottomInset)
                .padding(.horizontal, ChromeMetrics.Dock.horizontalInset)
            }
            .animation(.easeOut(duration: 0.15), value: notice)
        }
    }
}

/// The box every dock card shares. The shadow is for the grid alone: in the
/// rail a card sits in the chrome it is drawn on, and lifting it would read as
/// floating over something again.
struct DockCardChrome: ViewModifier {
    let theme: Theme
    let border: Color
    let isFloating: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ChromeMetrics.AttentionToast.horizontalPadding)
            .padding(.vertical, ChromeMetrics.AttentionToast.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.chrome, in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                    .strokeBorder(border, lineWidth: ChromeMetrics.ruleWidth)
            )
            .shadow(
                color: theme.chrome.opacity(isFloating ? ChromeMetrics.Dock.floatingShadowOpacity : 0),
                radius: ChromeMetrics.Dock.floatingShadowRadius,
                y: ChromeMetrics.Dock.floatingShadowY
            )
    }
}

/// Never takes a hit: it has nothing to offer a click, and over the grid the
/// card underneath keeps the mouse.
private struct NoticeCard: View {
    let theme: Theme
    let toast: ToastCenter.Toast
    let isFloating: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChromeMetrics.AttentionToast.dotSpacing) {
            // In the status dot's column, so the message starts where a
            // card's headline does.
            Image(systemName: symbolName)
                .font(ChromeType.toastSymbol)
                .foregroundStyle(iconColor)
                .frame(width: ChromeMetrics.AttentionToast.statusDot)
            Text(toast.message)
                .font(ChromeType.toastMessage)
                .foregroundStyle(theme.textStrong)
                .lineLimit(ChromeMetrics.Dock.noticeLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(DockCardChrome(theme: theme, border: theme.rule, isFloating: isFloating))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }

    /// The undo-arrow glyph is reserved for actual undo/redo notices;
    /// anything else (an invalid move, a plan/herdr failure from
    /// `perform`/`closePane`) gets a neutral info glyph instead -- neither
    /// is undoing anything, so the arrow would misdescribe it.
    private var symbolName: String {
        switch toast.kind {
        case .copied: "doc.on.doc"
        case .notice: "arrow.uturn.backward"
        case .info: "info.circle"
        }
    }

    /// `.copied` keeps the green success color; `.notice`/`.info` (which can
    /// be reporting a failure or a drop, not just a confirmation) get a
    /// neutral color instead -- reusing green there would read as "success"
    /// even for a "can't undo" or "can't move there" message.
    private var iconColor: Color {
        switch toast.kind {
        case .copied: theme.green
        case .notice, .info: theme.textDim
        }
    }
}
