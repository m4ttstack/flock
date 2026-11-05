import FlockCore
import SwiftUI

/// A tooltip drawn in the view tree: `.help` cannot be delayed, and a system
/// tip never shows over a pane, whose terminal surface owns the pointer. One
/// line, and an optional shortcut after it in a dimmer weight. The theme's
/// strong text and chrome swapped, so it inverts dark and light in every theme
/// and stands off the pane it hangs over.
struct DelayedTipLabel: View {
    let theme: Theme
    let text: String
    var shortcut: String?

    private typealias Metrics = ChromeMetrics.DelayedTip

    var body: some View {
        HStack(spacing: Metrics.shortcutGap) {
            Text(text).foregroundStyle(theme.chrome)
            if let shortcut {
                Text(shortcut).foregroundStyle(theme.chrome.opacity(Metrics.shortcutOpacity))
            }
        }
        .font(ChromeType.delayedTip)
        .fixedSize()
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(theme.textStrong))
        .allowsHitTesting(false)
    }
}

/// Where a shown tip hangs: below its control, flush with one of its sides. A
/// control sits near a pane's edge, and a centred tip would run past that edge.
struct TipBelow: ViewModifier {
    let theme: Theme
    var edge: HorizontalAlignment = .trailing
    let isShown: Bool
    let text: String
    let shortcut: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: Alignment(horizontal: edge, vertical: .bottom)) {
            if isShown {
                DelayedTipLabel(theme: theme, text: text, shortcut: shortcut)
                    .alignmentGuide(.bottom) { $0[.top] - ChromeMetrics.DelayedTip.gap }
                    .transition(.opacity)
            }
        }
    }
}

private struct DelayedTip: ViewModifier {
    let theme: Theme
    let edge: HorizontalAlignment
    let text: String
    let shortcut: String?
    @State private var isHovering = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .modifier(TipBelow(theme: theme, edge: edge, isShown: isShown, text: text, shortcut: shortcut))
            .task(id: isHovering) {
                guard isHovering else {
                    isShown = false
                    return
                }
                try? await Task.sleep(for: ChromeMetrics.DelayedTip.delay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { isShown = true }
            }
    }
}

extension View {
    /// The tip hangs just below the control. `edge` is the side of the control
    /// it lines up with: leading on the left of a pane, trailing on the right.
    func delayedTip(
        _ text: String, shortcut: String? = nil, theme: Theme, edge: HorizontalAlignment = .trailing
    ) -> some View {
        modifier(DelayedTip(theme: theme, edge: edge, text: text, shortcut: shortcut))
    }
}
