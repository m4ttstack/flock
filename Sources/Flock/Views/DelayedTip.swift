import FlockCore
import SwiftUI

/// A tooltip drawn in the view tree: `.help` cannot be delayed, and a system
/// tip never shows over a pane, whose terminal surface owns the pointer. One
/// line, and an optional shortcut after it in a dimmer weight.
struct DelayedTipLabel: View {
    let text: String
    var shortcut: String?

    private typealias Metrics = ChromeMetrics.DelayedTip

    var body: some View {
        HStack(spacing: Metrics.shortcutGap) {
            Text(text).foregroundStyle(.white)
            if let shortcut {
                Text(shortcut).foregroundStyle(.white.opacity(Metrics.shortcutOpacity))
            }
        }
        .font(ChromeType.delayedTip)
        .fixedSize()
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(white: Metrics.groundWhite)))
        .allowsHitTesting(false)
    }
}

/// Where a shown tip hangs: below a control one title row tall, its trailing
/// edge flush with the control's. The legend sits at a pane's right edge, and
/// a tip centred under it would run past the window.
struct TipBelow: ViewModifier {
    let isShown: Bool
    let text: String
    let shortcut: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isShown {
                DelayedTipLabel(text: text, shortcut: shortcut)
                    .offset(y: PaneChrome.titleRowHeight + ChromeMetrics.DelayedTip.gap)
                    .transition(.opacity)
            }
        }
    }
}

private struct DelayedTip: ViewModifier {
    let text: String
    let shortcut: String?
    @State private var isHovering = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .modifier(TipBelow(isShown: isShown, text: text, shortcut: shortcut))
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
    /// For a control one title row tall; the tip hangs just below it.
    func delayedTip(_ text: String, shortcut: String? = nil) -> some View {
        modifier(DelayedTip(text: text, shortcut: shortcut))
    }
}
