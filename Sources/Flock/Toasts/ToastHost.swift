import FlockCore
import SwiftUI

/// The window's bottom-right corner: a window-scope `ToastCenter.current`
/// nearest the edge, with the attention stack growing upward above it. One
/// column rather than two overlays, so a notice can never land on top of a
/// toast the user is about to click.
///
/// The notice sits closest to the corner because it is the transient half:
/// it replaces itself and leaves, while attention cards accumulate and wait
/// to be clicked. Putting the accumulating half on the outside means a new
/// card never shoves the others past where the user was already looking.
///
/// This corner is shared. A pane's own copied whisper and its attach badge
/// both draw bottom-right INSIDE their pane cell, so a toast can overlap the
/// bottom-right pane's furniture. Accepted deliberately: both of those are
/// brief and clear themselves, and the alternative was insetting this stack
/// by a number that would drift out of step with the pane chrome.
///
/// Only the attention stack takes hits. The notice never does: the pane
/// underneath keeps the mouse. A pane-scoped toast (`paneID != nil`, e.g. the
/// copied whisper) is skipped here -- it renders inside its own pane cell
/// instead (see `PaneCellView`).
struct ToastHost: View {
    let viewModel: SessionViewModel

    @Environment(ThemeStore.self) private var themeStore
    @Environment(ToastCenter.self) private var toastCenter

    var body: some View {
        // Zero spacing, with the gap owned by the attention stack: an empty
        // stack must leave the notice exactly where it sits on its own.
        VStack(alignment: .trailing, spacing: 0) {
            AttentionToastStackView(theme: themeStore.active, viewModel: viewModel)
            ZStack(alignment: .bottomTrailing) {
                if let toast = toastCenter.current, toast.paneID == nil {
                    ToastPill(theme: themeStore.active, toast: toast)
                        .id(toast.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: toastCenter.current)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.bottom, ChromeMetrics.Toast.bottomGap)
        .padding(.trailing, ChromeMetrics.Toast.trailingInset)
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
