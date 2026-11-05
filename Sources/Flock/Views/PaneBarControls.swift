import FlockCore
import SwiftUI

/// A pane bar button: bare until the pointer is on it, then the launcher
/// strip's hovered key.
struct PaneBarKeyStyle: ButtonStyle {
    let style: LauncherStripStyle
    var width: CGFloat? = ChromeMetrics.PaneBar.keySize.width

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let state: LauncherStripStyle.KeyState = configuration.isPressed ? .pressed : isHovering ? .hovered : .rest
        return configuration.label
            .foregroundStyle(style.text(state))
            .frame(width: width, height: ChromeMetrics.PaneBar.keySize.height)
            .background { PaneBarKeyGround(style: style, state: state) }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: ChromeMetrics.Launcher.hoverFade), value: state)
    }
}

/// Nothing at rest: the key exists only under the pointer.
private struct PaneBarKeyGround: View {
    let style: LauncherStripStyle
    let state: LauncherStripStyle.KeyState

    var body: some View {
        if state != .rest {
            let shape = RoundedRectangle(cornerRadius: ChromeMetrics.PaneBar.keyCornerRadius, style: .continuous)
            shape.fill(style.keyFill(state))
                .overlay(shape.strokeBorder(style.keyEdge(state), lineWidth: 1))
        }
    }
}

/// What the agent is doing, as one dot of one width, so a title never moves
/// with its state. Hovering names it.
struct PaneStatusDot: View {
    let theme: Theme
    let color: Color
    let label: String

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: M.dotSize, height: M.dotSize)
            .padding(.vertical, (M.keySize.height - M.dotSize) / 2)
            .contentShape(Rectangle())
            .delayedTip(label, theme: theme, edge: .leading)
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

/// Maximizes a pane within its tab: corners out, and corners in to restore.
/// The only place the window says a tab is zoomed, so it has to be readable.
struct PaneWindowButton: View {
    let theme: Theme
    let paneID: PaneID
    let isZoomed: Bool
    let action: () -> Void

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        Button(action: action) {
            PaneCornersGlyph(pointsIn: isZoomed)
                .stroke(style: StrokeStyle(lineWidth: M.glyphStroke, lineCap: .round, lineJoin: .round))
                .frame(width: M.glyphSize, height: M.glyphSize)
        }
        .buttonStyle(PaneBarKeyStyle(style: LauncherStripStyle(theme: theme)))
        .delayedTip(
            isZoomed ? "Restore" : "Maximize",
            shortcut: ShortcutLabel.text(key: KeyEquivalent(FocusedPaneCommand.zoom.key), modifiers: FocusedPaneCommand.zoom.modifiers),
            theme: theme, edge: .leading
        )
        .accessibilityLabel(isZoomed ? "Restore" : "Maximize")
        .accessibilityIdentifier("flock.pane.maximize.\(paneID.rawValue)")
    }
}

/// Four corners on a 24-unit grid, the ends turned inward for restore.
struct PaneCornersGlyph: Shape {
    let pointsIn: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let segments: [(CGPoint, CGPoint, CGPoint)] = pointsIn
            ? [
                (CGPoint(x: 8, y: 3), CGPoint(x: 8, y: 8), CGPoint(x: 3, y: 8)),
                (CGPoint(x: 16, y: 3), CGPoint(x: 16, y: 8), CGPoint(x: 21, y: 8)),
                (CGPoint(x: 3, y: 16), CGPoint(x: 8, y: 16), CGPoint(x: 8, y: 21)),
                (CGPoint(x: 21, y: 16), CGPoint(x: 16, y: 16), CGPoint(x: 16, y: 21)),
            ]
            : [
                (CGPoint(x: 8, y: 3), CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 8)),
                (CGPoint(x: 16, y: 3), CGPoint(x: 21, y: 3), CGPoint(x: 21, y: 8)),
                (CGPoint(x: 3, y: 16), CGPoint(x: 3, y: 21), CGPoint(x: 8, y: 21)),
                (CGPoint(x: 16, y: 21), CGPoint(x: 21, y: 21), CGPoint(x: 21, y: 16)),
            ]
        for (start, corner, end) in segments {
            path.move(to: start)
            path.addArc(tangent1End: corner, tangent2End: end, radius: 2)
            path.addLine(to: end)
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

/// A mouse on a 24-unit grid. A filled clicker stops at the centre line, so
/// that half drops its divider: the divider's own width would push the solid
/// area past the middle.
struct PaneMouseOutline: Shape {
    let hasDivider: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: 5, y: 2, width: 14, height: 20),
            cornerSize: CGSize(width: 7, height: 7)
        )
        path.move(to: CGPoint(x: 5, y: 10))
        path.addLine(to: CGPoint(x: 19, y: 10))
        if hasDivider {
            path.move(to: CGPoint(x: 12, y: 2))
            path.addLine(to: CGPoint(x: 12, y: 10))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

/// The right clicker, following the outline's top-right curve.
struct PaneMouseClicker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 2))
        path.addCurve(to: CGPoint(x: 19, y: 9), control1: CGPoint(x: 15.87, y: 2), control2: CGPoint(x: 19, y: 5.13))
        path.addLine(to: CGPoint(x: 19, y: 10))
        path.addLine(to: CGPoint(x: 12, y: 10))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

/// A pane that is not signed in. It keeps its key at rest, as the name chip
/// does: chat is the one control that always shows it is there.
struct ChatSignedOutButton: View {
    let theme: Theme
    let paneID: PaneID
    let action: () -> Void

    @State private var isHovering = false

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        let style = LauncherStripStyle(theme: theme)
        let state: LauncherStripStyle.KeyState = isHovering ? .hovered : .rest
        let shape = RoundedRectangle(cornerRadius: M.keyCornerRadius, style: .continuous)
        Button(action: action) {
            ChatGlyph(color: style.text(state))
                .frame(width: ChromeMetrics.ChatButton.iconSize.width, height: ChromeMetrics.ChatButton.iconSize.height)
                .frame(width: M.keySize.width, height: M.keySize.height)
                .background(shape.fill(style.keyFill(state)))
                .overlay(shape.strokeBorder(style.keyEdge(state), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Chat")
        .accessibilityIdentifier("flock.pane.chatButton.\(paneID.rawValue)")
    }
}
