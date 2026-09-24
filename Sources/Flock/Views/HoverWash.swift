import FlockCore
import SwiftUI

/// The legend controls' hover: a faint wash of the text colour over the
/// hovered target, the same on every chip whatever its own fill.
struct HoverWashFill: View {
    let theme: Theme
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.text.opacity(ChromeMetrics.HoverWash.opacity))
            .allowsHitTesting(false)
    }
}

private struct HoverWash: ViewModifier {
    let theme: Theme
    let cornerRadius: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay { if isHovering { HoverWashFill(theme: theme, cornerRadius: cornerRadius) } }
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverWash(_ theme: Theme, cornerRadius: CGFloat) -> some View {
        modifier(HoverWash(theme: theme, cornerRadius: cornerRadius))
    }
}
