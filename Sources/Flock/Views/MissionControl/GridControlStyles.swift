import FlockCore
import SwiftUI

/// A forced hover and press, for renders: a test cannot move a pointer or
/// build a `ButtonStyle.Configuration`.
struct ControlInteraction: Equatable {
    var isHovering: Bool
    var isPressed: Bool

    static let rest = ControlInteraction(isHovering: false, isPressed: false)
    static let hover = ControlInteraction(isHovering: true, isPressed: false)
    static let pressed = ControlInteraction(isHovering: true, isPressed: true)
}

/// Rest, hover and press for the All Workspaces view's controls, resolved
/// apart from the style so each state can be asserted.
struct GridControlAppearance: Equatable {
    /// `HoverWashFill`'s neutral lift, drawn over the control's resting
    /// ground rather than instead of it, so a selected segment or a blocked
    /// card keeps what it already says.
    let lift: Color
    let foreground: Color
    let pressWash: Double

    static func resolve(
        theme: Theme, restForeground: Color, pressAccent: Double = ChromeMetrics.Launcher.pressedAccent,
        hoverLift: Double = ChromeMetrics.HoverWash.opacity, isHovering: Bool, isPressed: Bool
    ) -> GridControlAppearance {
        let lit = isHovering || isPressed
        return GridControlAppearance(
            lift: lit ? theme.text.opacity(hoverLift) : .clear,
            foreground: lit ? theme.textStrong : restForeground,
            pressWash: isPressed ? pressAccent : 0
        )
    }
}

/// The ground of a control in the state `appearance` names: its rest fill,
/// the hover lift over it, and the press's accent over both.
struct GridControlGround: View {
    let theme: Theme
    let shape: AnyShape
    let restFill: Color
    let appearance: GridControlAppearance

    var body: some View {
        shape.fill(restFill)
            .overlay(shape.fill(appearance.lift))
            .overlay(shape.fill(theme.accent).opacity(appearance.pressWash))
            .allowsHitTesting(false)
    }
}

/// A label on a `GridControlGround`. The hover fade is driven by the view that
/// owns `isHovering`; only the press animates here.
struct GridControlStyle: ButtonStyle {
    let theme: Theme
    let shape: AnyShape
    let restFill: Color
    let restForeground: Color
    var pressAccent = ChromeMetrics.Launcher.pressedAccent
    var hoverLift = ChromeMetrics.HoverWash.opacity
    let isHovering: Bool
    var forcePressed = false

    func makeBody(configuration: Configuration) -> some View {
        Body(style: self, label: configuration.label, isPressed: configuration.isPressed || forcePressed)
    }

    private struct Body<Label: View>: View {
        let style: GridControlStyle
        let label: Label
        let isPressed: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let appearance = GridControlAppearance.resolve(
                theme: style.theme, restForeground: style.restForeground, pressAccent: style.pressAccent,
                hoverLift: style.hoverLift, isHovering: style.isHovering, isPressed: isPressed
            )
            label
                .foregroundStyle(appearance.foreground)
                .background(
                    GridControlGround(theme: style.theme, shape: style.shape, restFill: style.restFill, appearance: appearance)
                )
                .contentShape(style.shape)
                .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isPressed)
        }
    }
}

/// A button in the All Workspaces view, holding its own hover so each one
/// answers only for the pointer being over itself.
struct GridControlButton<Label: View>: View {
    let theme: Theme
    let shape: AnyShape
    var restFill: Color = .clear
    let restForeground: Color
    /// False while a drag is live, when a drop target's own wash is the only
    /// thing it should show.
    var hoverEnabled = true
    var forced: ControlInteraction?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(GridControlStyle(
                theme: theme, shape: shape, restFill: restFill, restForeground: restForeground,
                isHovering: (forced?.isHovering ?? isHovering) && hoverEnabled,
                forcePressed: forced?.isPressed ?? false
            ))
            .fadingHover($isHovering)
    }
}

/// The part of an Arrange thumbnail under the pointer, which is what a drag
/// from there picks up: the tab (its handle or the padding around the mini
/// panes) or one pane.
enum ThumbnailPart: Equatable {
    case tab
    case pane(PaneID)

    /// Only the part a drag would pick up lights, and nothing does while a
    /// drag is live, when the drop wash says where it lands.
    static func interaction(
        of part: ThumbnailPart, hovered: ThumbnailPart?, pressed: ThumbnailPart?, dragInFlight: Bool
    ) -> ControlInteraction {
        guard !dragInFlight else { return .rest }
        return ControlInteraction(isHovering: hovered == part, isPressed: pressed == part)
    }

    /// The whole thumbnail's outline: on only while the tab is the part, so
    /// a pane under the pointer never reads as the tab. An outline, so it
    /// never meets the drop wash (a fill) or the focused tab's handle tint.
    static func thumbnailOutline(theme: Theme, tab: ControlInteraction) -> Color {
        tab.isHovering || tab.isPressed ? theme.textDim : .clear
    }

    /// A mini pane's outline. Previewed and blocked keep theirs; hover
    /// draws one only where neither already does.
    static func paneOutline(theme: Theme, status: AgentStatus, isPreviewed: Bool, pane: ControlInteraction) -> Color {
        if isPreviewed { return theme.accent }
        if status == .blocked { return theme.red }
        return pane.isHovering || pane.isPressed ? theme.textDim : .clear
    }
}

enum GridControlFade {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: ChromeMetrics.Launcher.hoverFade)
    }
}

private struct FadingHover: ViewModifier {
    @Binding var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onHover { hovering in
            withAnimation(GridControlFade.animation(reduceMotion: reduceMotion)) { isHovering = hovering }
        }
    }
}

extension View {
    /// Tracks the pointer into `isHovering`, fading the change unless Reduce
    /// Motion is on.
    func fadingHover(_ isHovering: Binding<Bool>) -> some View {
        modifier(FadingHover(isHovering: isHovering))
    }
}
