import FlockCore
import SwiftUI

/// The slot a previewed drop opens among a thumbnail's mini panes, drawn in
/// the canvas's own preview language: the wash alone. It opens out of and
/// closes back into its collapsed line under whatever animation moves the
/// panes around it, which is what keeps the two in step.
struct DropReflowSlot: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: ChromeRadius.control)
            .fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
            .allowsHitTesting(false)
    }

    static func transition(_ slot: DropReflow.Slot) -> AnyTransition {
        .modifier(active: DropReflowFrame(frame: slot.collapsed), identity: DropReflowFrame(frame: slot.frame))
    }
}

/// A rect stated in the pane area's space, as the mini panes are placed.
struct DropReflowFrame: ViewModifier {
    let frame: CGRect

    func body(content: Content) -> some View {
        content
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
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
