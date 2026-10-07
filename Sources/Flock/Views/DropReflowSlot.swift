import FlockCore
import SwiftUI

/// The slot a previewed drop opens among a thumbnail's mini panes, drawn in
/// the canvas's own preview language: the wash alone. It opens out of and
/// closes back into its collapsed line under whatever animation moves the
/// panes around it, which is what keeps the two in step.
///
/// The slot places itself; the transition only reveals it. Some SwiftUI
/// releases never apply a `.modifier` transition's identity once the view is
/// in, so a slot placed by its transition fills the whole pane area there.
struct DropReflowSlot: View {
    let theme: Theme
    let frame: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: ChromeRadius.control)
            .fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
            .modifier(DropReflowFrame(frame: frame))
            .allowsHitTesting(false)
    }

    static func transition(_ slot: DropReflow.Slot) -> AnyTransition {
        .modifier(active: DropReflowReveal(shown: slot.collapsed), identity: DropReflowReveal(shown: slot.frame))
    }
}

/// A rect stated in the pane area's space, as the mini panes are placed.
/// Padding rather than an offset, so the view's own space is the pane area's
/// and a mask over it lands where the rect does.
struct DropReflowFrame: ViewModifier {
    let frame: CGRect

    func body(content: Content) -> some View {
        content
            .frame(width: frame.width, height: frame.height)
            .padding(.leading, frame.minX)
            .padding(.top, frame.minY)
    }
}

/// Shows only `shown` of a slot, with the slot's own corners, so a slot
/// opening out of its line reads as the rounded wash growing.
struct DropReflowReveal: ViewModifier {
    let shown: CGRect

    func body(content: Content) -> some View {
        content.mask(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: ChromeRadius.control)
                .modifier(DropReflowFrame(frame: shown))
        }
    }
}

enum DropReflowMotion {
    /// One curve for the panes and the slot together.
    static let animation = Animation.easeOut(duration: DragVisuals.reshuffleDuration)
}

private struct DropReflowPreviewKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Draws every drop preview in Arrange held part of the way open, for the
    /// render tests: an offscreen snapshot sees only the model state of a
    /// running animation, never a frame of it.
    var dropReflowPreviewProgress: CGFloat? {
        get { self[DropReflowPreviewKey.self] }
        set { self[DropReflowPreviewKey.self] = newValue }
    }
}
