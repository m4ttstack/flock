import PaddockCore
import SwiftUI

/// Draws a window-scope `ToastCenter.current` in the window's top-right
/// corner, below the title bar, and never takes hits: the pane underneath
/// keeps the mouse. A pane-scoped toast (`paneID != nil`, e.g. the copied
/// whisper) is skipped here -- it renders inside its own pane cell instead
/// (see `PaneCellView`).
struct ToastHost: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(ToastCenter.self) private var toastCenter

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let toast = toastCenter.current, toast.paneID == nil {
                ToastPill(theme: themeStore.active, toast: toast)
                    .id(toast.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, ChromeMetrics.TitleBar.height + ChromeMetrics.Strip.height + ChromeMetrics.ruleWidth + ChromeMetrics.Toast.topGap)
        .padding(.trailing, ChromeMetrics.Toast.trailingInset)
        .animation(.easeOut(duration: 0.15), value: toastCenter.current)
        .allowsHitTesting(false)
    }
}

private struct ToastPill: View {
    let theme: Theme
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: ChromeMetrics.Toast.spacing) {
            Image(systemName: symbolName)
                .font(ChromeType.toastSymbol)
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(ChromeType.toastMessage)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, ChromeMetrics.Toast.horizontalPadding)
        .padding(.vertical, ChromeMetrics.Toast.verticalPadding)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(theme.rule, lineWidth: 1))
        .shadow(color: theme.chrome.opacity(0.6), radius: ChromeMetrics.Toast.shadowRadius, y: ChromeMetrics.Toast.shadowY)
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
