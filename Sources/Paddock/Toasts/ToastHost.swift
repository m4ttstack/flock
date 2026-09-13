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
        .padding(.top, 54)
        .padding(.trailing, 14)
        .animation(.easeOut(duration: 0.15), value: toastCenter.current)
        .allowsHitTesting(false)
    }
}

private struct ToastPill: View {
    let theme: Theme
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.green)
            Text(toast.message)
                .font(.system(size: 11))
                .foregroundStyle(theme.chromeTextStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.paneHeaderBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.tabPillSelectedBorder, lineWidth: 1))
        .shadow(color: theme.railBg.opacity(0.6), radius: 9, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }

    private var symbolName: String {
        switch toast.kind {
        case .copied: "doc.on.doc"
        }
    }
}
