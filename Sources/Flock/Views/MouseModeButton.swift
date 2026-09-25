import FlockCore
import SwiftUI

/// A pane's right-click mode, shown while its program has the mouse: a mouse
/// whose right button is lit when right-clicks go to the program. A click
/// flips the mode.
struct MouseModeButton: View {
    let theme: Theme
    let paneID: PaneID
    let mode: RightClickMode
    let onToggle: (() -> Void)?

    @State private var isHovering = false

    private typealias Metrics = ChromeMetrics.Pane.MouseGlyph

    var body: some View {
        Button {
            onToggle?()
        } label: {
            MouseGlyph(
                outline: isHovering && onToggle != nil ? theme.textDim : theme.overlay0,
                rightButton: mode == .menu ? nil : theme.accent
            )
            .frame(width: Metrics.chipSize.width, height: Metrics.chipSize.height)
            .background(RoundedRectangle(cornerRadius: Metrics.chipCornerRadius).fill(Color(theme.palette.surface0)))
            .overlay { if isHovering && onToggle != nil { HoverWashFill(theme: theme, cornerRadius: Metrics.chipCornerRadius) } }
            .frame(height: PaneChrome.titleRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onToggle == nil)
        .onHover { isHovering = $0 }
        .delayedTip(tip, shortcut: "⌥⌘M")
        .accessibilityLabel("Right-clicks")
        .accessibilityValue(mode == .menu ? "flock's menu" : "the program")
        .accessibilityIdentifier("flock.pane.mouseBadge.\(paneID.rawValue)")
    }

    private var tip: String {
        mode == .menu ? "Right-clicks open flock's menu" : "Right-clicks go to the program"
    }
}

/// A mouse outline with a cord, its two buttons split across the top, the
/// right one filled when `rightButton` is set.
struct MouseGlyph: View {
    let outline: Color
    let rightButton: Color?

    private typealias Metrics = ChromeMetrics.Pane.MouseGlyph

    var body: some View {
        Canvas { context, size in
            let body = CGRect(
                x: (size.width - Metrics.bodyWidth) / 2,
                y: (size.height - Metrics.bodyHeight - Metrics.cordRise) / 2 + Metrics.cordRise,
                width: Metrics.bodyWidth, height: Metrics.bodyHeight
            )
            let shell = Path(roundedRect: body, cornerRadius: Metrics.cornerRadius)
            let buttonLine = body.minY + Metrics.buttonDepth
            if let rightButton {
                var clipped = context
                clipped.clip(to: shell)
                clipped.fill(
                    Path(CGRect(x: body.midX, y: body.minY, width: body.width / 2, height: Metrics.buttonDepth)),
                    with: .color(rightButton)
                )
            }
            var lines = Path()
            lines.move(to: CGPoint(x: body.minX, y: buttonLine))
            lines.addLine(to: CGPoint(x: body.maxX, y: buttonLine))
            lines.move(to: CGPoint(x: body.midX, y: body.minY))
            lines.addLine(to: CGPoint(x: body.midX, y: buttonLine))
            var cord = Path()
            cord.move(to: CGPoint(x: body.midX, y: body.minY))
            cord.addCurve(
                to: CGPoint(x: body.midX + Metrics.cordReach, y: body.minY - Metrics.cordRise),
                control1: CGPoint(x: body.midX, y: body.minY - Metrics.cordRise * 0.8),
                control2: CGPoint(x: body.midX + Metrics.cordReach * 0.3, y: body.minY - Metrics.cordRise)
            )
            let stroke = StrokeStyle(lineWidth: Metrics.stroke, lineCap: .round)
            context.stroke(shell, with: .color(outline), style: stroke)
            context.stroke(lines, with: .color(outline), style: stroke)
            context.stroke(cord, with: .color(outline), style: stroke)
        }
    }
}
