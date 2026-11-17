import AppKit
import SwiftUI

/// Whether the latest input was a key or the mouse, and where the pointer is,
/// in the space of the view it backs.
@MainActor
final class ConfirmInputSource {
    weak var view: NSView?
    var lastWasPointer = false
    var lastPress: CGPoint?

    /// How the card about to show was raised, read once as it shows.
    func origin() -> ConfirmOrigin {
        guard lastWasPointer else { return .keyboard }
        guard let view, let window = view.window else { return .keyboard }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let onTitleBar = lastPress.map { $0.y < ChromeMetrics.TitleBar.height } ?? false
        return .pointer(view.bounds.contains(point) ? point : nil, pressOnTitleBar: onTitleBar)
    }
}

struct ConfirmInputMonitor: NSViewRepresentable {
    let source: ConfirmInputSource
    let isActive: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        source.view = view
        view.source = source
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        source.view = view
        view.source = source
        view.isActive = isActive
        view.onKey = onKey
    }

    final class MonitorView: NSView {
        weak var source: ConfirmInputSource?
        var isActive = false
        var onKey: (NSEvent) -> Void = { _ in }
        nonisolated(unsafe) private var monitors: [Any] = []

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            guard let window else { return }
            let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                self.source?.lastWasPointer = false
                guard self.isActive else { return event }
                self.onKey(event)
                return nil
            }
            let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                self.source?.lastWasPointer = true
                self.source?.lastPress = event.window === window ? self.convert(event.locationInWindow, from: nil) : nil
                return event
            }
            monitors = [keys, mouse].compactMap { $0 }
        }
    }
}

/// The card's entrance and exit: a short fade with a slight grow from where it
/// sits, so it arrives without a sheet's long slide.
struct CardMotion: ViewModifier {
    let isIn: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(isIn ? 1 : ChromeMetrics.ConfirmCard.enterScale, anchor: anchor)
            .opacity(isIn ? 1 : 0)
    }
}

/// Flock's own button rather than the system's: a bordered or prominent
/// button greys out in a window that is not key, and its system blue belongs
/// to no theme.
struct ConfirmCardButtonStyle: ButtonStyle {
    let fill: Color
    /// A faint fill has no colour to darken, so it states its pressed look;
    /// nil darkens `fill`.
    let pressedFill: Color?
    let ink: Color

    private typealias M = ChromeMetrics.ConfirmCard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.confirmCardButton)
            .foregroundStyle(ink)
            .padding(.horizontal, M.buttonHorizontalPadding)
            .frame(height: M.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: M.buttonCornerRadius)
                    .fill(configuration.isPressed ? (pressedFill ?? fill) : fill)
                    .brightness(configuration.isPressed && pressedFill == nil ? -0.08 : 0)
            )
            .contentShape(Rectangle())
    }
}

enum ConfirmCardItem {
    case dontWarn, cancel, confirm
}

/// The keyboard's place on the card, drawn the way macOS draws a focus ring:
/// an accent outline standing just off the control.
struct SelectionRing: ViewModifier {
    let isSelected: Bool
    let color: Color
    /// Room between a control with no fill of its own and its ring. The
    /// control keeps its place; only the ring stands further out.
    var inset: CGSize = .zero

    private typealias M = ChromeMetrics.ConfirmCard

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, inset.width)
            .padding(.vertical, inset.height)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: M.buttonCornerRadius + M.ringOffset)
                        .strokeBorder(color.opacity(M.ringOpacity), lineWidth: M.ringWidth)
                        .padding(-M.ringOffset)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -inset.width)
            .padding(.vertical, -inset.height)
    }
}

extension VerticalAlignment {
    /// Where a centred card rests: above the canvas's middle, where the eye
    /// already is, rather than dead centre.
    enum ConfirmCardRest: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context.height * ChromeMetrics.ConfirmCard.restHeightFraction
        }
    }

    static let confirmCardRest = VerticalAlignment(ConfirmCardRest.self)
}

/// A rounded card, with an arrow on its top edge at `arrowX` pointing up at
/// whatever it hangs from. One outline, so the stroke runs unbroken round the
/// arrow and the card alike.
struct CalloutShape: InsettableShape {
    let cornerRadius: CGFloat
    let arrowX: CGFloat?
    let arrowWidth: CGFloat
    let arrowHeight: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let outer = rect.insetBy(dx: inset, dy: inset)
        let radius = max(0, cornerRadius - inset)
        guard let arrowX else { return Path(roundedRect: outer, cornerRadius: radius) }
        let body = CGRect(x: outer.minX, y: outer.minY + arrowHeight, width: outer.width, height: outer.height - arrowHeight)
        let tipX = rect.minX + arrowX
        let half = max(0, arrowWidth / 2 - inset)
        var arrow = Path()
        arrow.move(to: CGPoint(x: tipX - half, y: body.minY + 1))
        arrow.addLine(to: CGPoint(x: tipX, y: outer.minY))
        arrow.addLine(to: CGPoint(x: tipX + half, y: body.minY + 1))
        arrow.closeSubpath()
        return Path(roundedRect: body, cornerRadius: radius).union(arrow)
    }

    func inset(by amount: CGFloat) -> CalloutShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
