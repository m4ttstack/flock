import AppKit
import SwiftUI

/// One for the app, rather than a view per card: a view mounted behind the
/// window's root kept the rail's rename field from opening. It knows whether
/// the latest input was a key or the mouse and where the last press landed,
/// and hands every key to the card that is showing.
@MainActor
final class ConfirmInputTracker {
    static let shared = ConfirmInputTracker()

    private var lastWasPointer = false
    private var lastPress: (window: NSWindow, point: CGPoint)?
    private var keyTaker: KeyTaker?
    private var monitors: [Any] = []

    private init() {}

    /// Installed by the first card a window mounts; later calls do nothing.
    func start() {
        guard monitors.isEmpty else { return }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.lastWasPointer = false
            guard let taker = self.keyTaker, let window = taker.window, event.window === window else { return event }
            taker.handle(event)
            return nil
        }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.lastWasPointer = true
            self.lastPress = event.window.map { ($0, Self.topLeft(event.locationInWindow, in: $0)) }
            return event
        }
        monitors = [keys, mouse].compactMap { $0 }
    }

    /// How a card about to show in `window` was raised, in the window's
    /// content space, top-left, which is the space the card is laid out in.
    func origin(in window: NSWindow?) -> ConfirmOrigin {
        guard lastWasPointer, let window, let content = window.contentView else { return .keyboard }
        let point = Self.topLeft(window.mouseLocationOutsideOfEventStream, in: window)
        let inside = CGRect(origin: .zero, size: content.bounds.size).contains(point)
        let onTitleBar = lastPress.map { $0.window === window && $0.point.y < ChromeMetrics.TitleBar.height } ?? false
        return .pointer(inside ? point : nil, pressOnTitleBar: onTitleBar)
    }

    /// The newest card takes its window's keys. Held weakly, so a window
    /// that closes under a card gives them back.
    func takeKeys(_ id: UUID, in window: NSWindow?, handle: @escaping (NSEvent) -> Void) {
        guard let window else { return }
        keyTaker = KeyTaker(id: id, window: window, handle: handle)
    }

    func releaseKeys(_ id: UUID) {
        if keyTaker?.id == id { keyTaker = nil }
    }

    private final class KeyTaker {
        let id: UUID
        weak var window: NSWindow?
        let handle: (NSEvent) -> Void

        init(id: UUID, window: NSWindow, handle: @escaping (NSEvent) -> Void) {
            self.id = id
            self.window = window
            self.handle = handle
        }
    }

    private static func topLeft(_ point: NSPoint, in window: NSWindow) -> CGPoint {
        CGPoint(x: point.x, y: (window.contentView?.bounds.height ?? 0) - point.y)
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
