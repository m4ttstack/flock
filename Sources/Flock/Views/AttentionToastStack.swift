import AppKit
import FlockCore
import SwiftUI

/// The dock's attention cards: one per pane that wants the user, newest
/// first, over a "+N more" pill once there are more than three. Every rule
/// about what is in it lives in `AttentionToastStack`; this draws what the
/// rules decided and owns only the pointer.
struct AttentionToastStackView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let isFloating: Bool

    @State private var isHovering = false

    private var stack: AttentionToastStack { viewModel.attentionToasts }

    var body: some View {
        if !stack.isEmpty {
            VStack(alignment: .leading, spacing: ChromeMetrics.Dock.itemSpacing) {
                ForEach(stack.visible) { toast in
                    AttentionToastCard(theme: theme, toast: toast, viewModel: viewModel, isFloating: isFloating)
                        .transition(.opacity)
                }
                if stack.collapsedCount > 0 {
                    MorePill(theme: theme, count: stack.collapsedCount)
                }
            }
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

/// Two lines sized for a rail as narrow as 150pt. What the pane wants leads
/// and is never cut; the pane's own title takes what the line has left. The
/// breadcrumb keeps its end, which is what tells two panes apart, and shares
/// its line with the two controls so the headline has the card's full width.
private struct AttentionToastCard: View {
    let theme: Theme
    let toast: AttentionToast
    let viewModel: SessionViewModel
    let isFloating: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.AttentionToast.lineSpacing) {
            HStack(spacing: ChromeMetrics.AttentionToast.dotSpacing) {
                StatusDot(status: toast.status, theme: theme, size: ChromeMetrics.AttentionToast.statusDot)
                    .shadow(
                        color: toast.kind == .needsInput ? theme.red.opacity(0.7) : .clear,
                        radius: ChromeMetrics.AttentionToast.blockedGlowRadius
                    )
                // Judged on the subject's minimum rather than its whole
                // width, so a long title still shows as much as fits.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ChromeMetrics.AttentionToast.subjectGap) {
                        headline
                        Text(toast.subject)
                            .font(ChromeType.attentionToastSubject)
                            .foregroundStyle(theme.textDim)
                            .lineLimit(1)
                            .frame(
                                minWidth: ChromeMetrics.AttentionToast.minimumSubjectWidth,
                                idealWidth: ChromeMetrics.AttentionToast.minimumSubjectWidth,
                                alignment: .leading
                            )
                    }
                    headline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: ChromeMetrics.AttentionToast.breadcrumbToGlyphs) {
                Text(toast.breadcrumb)
                    .font(ChromeType.attentionToastBreadcrumb)
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingGlyphs
            }
            .padding(.leading, ChromeMetrics.AttentionToast.statusDot + ChromeMetrics.AttentionToast.dotSpacing)
        }
        .modifier(DockCardChrome(theme: theme, border: borderColor, isFloating: isFloating))
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

    private var headline: some View {
        Text(toast.kind.label)
            .font(ChromeType.attentionToastHeadline)
            .foregroundStyle(theme.textStrong)
            .lineLimit(1)
            .fixedSize()
    }

    /// Two slots, never one. The arrow says "this jumps" and the x says "this
    /// dismisses", so they cannot share pixels: stacked, the arrow was what a
    /// resting card showed and the x was what the pointer armed, and aiming
    /// at the arrow dismissed the toast instead of jumping to the pane.
    ///
    /// Both slots exist at every moment so a card never reflows as the
    /// pointer crosses it; only the x's opacity and hit testing follow hover.
    /// Fixed as a pair, so a narrow card takes its room from the breadcrumb
    /// and never from the daylight between them.
    private var trailingGlyphs: some View {
        HStack(spacing: ChromeMetrics.AttentionToast.glyphSpacing) {
            Image(systemName: "arrow.right")
                .font(ChromeType.attentionToastGlyph)
                .foregroundStyle(theme.textLabel)
                .frame(width: ChromeMetrics.AttentionToast.jumpGlyphWidth)
                .accessibilityIdentifier("flock.attention.jump.\(toast.paneID.rawValue)")
            HoverCloseButton(
                theme: theme, isRevealed: isHovering, help: "Dismiss",
                accessibilityIdentifier: "flock.attention.dismiss.\(toast.paneID.rawValue)",
                action: { viewModel.dismissAttentionToast(pane: toast.paneID) }
            )
            .frame(width: ChromeMetrics.AttentionToast.dismissGlyphWidth)
        }
        .fixedSize()
    }

    /// A pane waiting on the user carries its status in the border too: the
    /// dock is read from the corner of the eye, and one dot is not enough
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
            .accessibilityIdentifier("flock.attention.more")
    }
}
