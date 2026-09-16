import AppKit
import PaddockCore
import SwiftUI

/// The top-right attention stack: one card per pane that wants the user, over
/// a "+N more" pill once there are more than three. Every rule about what is
/// in it lives in `AttentionToastStack`; this draws what the rules decided
/// and owns only the pointer.
struct AttentionToastStackView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @State private var isHovering = false

    private var stack: AttentionToastStack { viewModel.attentionToasts }

    var body: some View {
        if !stack.isEmpty {
            VStack(alignment: .trailing, spacing: ChromeMetrics.AttentionToast.stackSpacing) {
                ForEach(stack.visible) { toast in
                    AttentionToastCard(theme: theme, toast: toast, viewModel: viewModel)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if stack.collapsedCount > 0 {
                    MorePill(theme: theme, count: stack.collapsedCount)
                }
            }
            .padding(.bottom, ChromeMetrics.AttentionToast.stackSpacing)
            .animation(.easeOut(duration: 0.15), value: stack.visible.map(\.id))
            // The whole stack, not one card: cards vanishing out from under a
            // pointer that is reading them is what the pause exists to stop.
            .onHover { isHovering = $0 }
            // Runs for as long as anything is on screen, not just while a
            // finished toast is counting down: the sweep is also what notices
            // that a "needs input" toast's coalescing grace has expired, and
            // that toast has no clock of its own. Bound to this branch of the
            // `if`, so an empty stack costs nothing.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: ChromeMetrics.AttentionToast.sweepInterval)
                    if Task.isCancelled { return }
                    guard !isHovering else { continue }
                    viewModel.sweepAttentionToasts()
                }
            }
        }
    }
}

private struct AttentionToastCard: View {
    let theme: Theme
    let toast: AttentionToast
    let viewModel: SessionViewModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: ChromeMetrics.AttentionToast.dotSpacing) {
            StatusDot(status: toast.status, theme: theme, size: ChromeMetrics.AttentionToast.statusDot)
                .shadow(
                    color: toast.kind == .needsInput ? theme.red.opacity(0.7) : .clear,
                    radius: ChromeMetrics.AttentionToast.blockedGlowRadius
                )
            VStack(alignment: .leading, spacing: ChromeMetrics.AttentionToast.lineSpacing) {
                Text(toast.headline)
                    .font(ChromeType.attentionToastHeadline)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                Text(toast.breadcrumb)
                    .font(ChromeType.attentionToastBreadcrumb)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingGlyph
        }
        .padding(.horizontal, ChromeMetrics.AttentionToast.horizontalPadding)
        .padding(.vertical, ChromeMetrics.AttentionToast.verticalPadding)
        .frame(width: ChromeMetrics.AttentionToast.width)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
                .strokeBorder(borderColor, lineWidth: ChromeMetrics.ruleWidth)
        )
        .shadow(
            color: theme.chrome.opacity(0.6),
            radius: ChromeMetrics.AttentionToast.shadowRadius,
            y: ChromeMetrics.AttentionToast.shadowY
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Guarded like every other chrome tap: SwiftUI's tap gesture on macOS
        // fires for the secondary button too, so without this a right-click
        // would jump the window as well as opening whatever menu it wanted.
        .onTapGesture {
            guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
            NSApp.activate()
            Task { await viewModel.jumpToAttentionToast(pane: toast.paneID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(toast.accessibilityIdentifier)
    }

    /// The jump arrow at rest, the dismiss x under the pointer, both in the
    /// same fixed box so a card never reflows as the pointer crosses it.
    private var trailingGlyph: some View {
        ZStack {
            Image(systemName: "arrow.right")
                .font(ChromeType.attentionToastGlyph)
                .foregroundStyle(theme.textLabel)
                .opacity(isHovering ? 0 : 1)
            HoverCloseButton(
                theme: theme, isRevealed: isHovering, help: "Dismiss",
                accessibilityIdentifier: "paddock.attention.dismiss.\(toast.paneID.rawValue)",
                action: { viewModel.dismissAttentionToast(pane: toast.paneID) }
            )
        }
        .frame(width: ChromeMetrics.AttentionToast.trailingGlyphWidth)
    }

    /// A pane waiting on the user carries its status in the border too: the
    /// stack is read from the corner of the eye, and one dot is not enough
    /// separation between "answer me" and "I finished".
    private var borderColor: Color {
        switch toast.kind {
        case .needsInput: theme.red.opacity(ChromeMetrics.AttentionToast.borderOpacity)
        case .finished: theme.rule
        }
    }
}

private struct MorePill: View {
    let theme: Theme
    let count: Int

    var body: some View {
        Text("+\(count) more")
            .font(ChromeType.attentionToastPill)
            .foregroundStyle(theme.textLabel)
            .padding(.horizontal, ChromeMetrics.AttentionToast.pillHorizontalPadding)
            .padding(.vertical, ChromeMetrics.AttentionToast.pillVerticalPadding)
            .background(theme.chrome, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
            .accessibilityIdentifier("paddock.attention.more")
    }
}
