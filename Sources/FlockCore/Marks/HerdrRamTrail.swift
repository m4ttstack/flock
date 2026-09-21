import CoreGraphics

/// The ram and its three-echo motion trail, as vector geometry rather than a
/// flattened image -- `Scripts/make-icon.swift`'s own four fills of
/// `HerdrRam.path()` (three echoes plus the leader), with the squircle ground
/// and its clip dropped. Every fraction below is copied from that script
/// so the loader's fit can never drift from the icon's.
public enum HerdrRamTrail {
    /// One echo's resting geometry, before any animation is applied.
    public struct Echo: Equatable, Sendable {
        /// Steps behind the leader at rest, matching `make-icon.swift`'s
        /// `back` (farthest echo has the most steps).
        public let restBackSteps: CGFloat
        public let restOpacity: Double
        /// How long after the loop starts this echo begins gathering --
        /// what keeps the trail reading as one thing catching up rather
        /// than three shapes sliding as a block.
        public let startDelay: Double
    }

    public static let echoCount = 3
    /// Seconds between one echo's start and the next.
    public static let staggerDelay: Double = 0.05

    public static let echoes: [Echo] = (0..<echoCount).map { index in
        Echo(
            restBackSteps: CGFloat(echoCount - index),
            restOpacity: 0.58 + 0.13 * Double(index),
            startDelay: staggerDelay * Double(index)
        )
    }

    /// The mark's own brand colours, lifted verbatim from
    /// `Scripts/make-icon.swift`. This is a logo, not chrome: it has to read
    /// the same ram under every pane theme, the way the app icon itself does
    /// not repaint per theme, so these never come from `ThemePalette` --
    /// picking them from the active theme was tried and reverted, because a
    /// theme with a green or orange accent turned the ram a colour that read
    /// as a different mark entirely.
    public enum Colors {
        public static let leader = RGB(0xD8, 0xAD, 0xFE)
        /// One entry per `echoes` index: farthest from the leader first.
        public static let echoes: [RGB] = [
            RGB(0x6A, 0x8A, 0xEF),
            RGB(0xA3, 0x7A, 0xEF),
            RGB(0xE0, 0x84, 0xD4),
        ]
    }

    private static let insetFraction: CGFloat = 0.086
    private static let marginFraction: CGFloat = 0.19
    private static let heightFillFraction: CGFloat = 0.87
    private static let echoStepXFraction: CGFloat = 0.105
    private static let echoStepYFraction: CGFloat = 0.075

    /// The ram, fit into `square` and centred on the WHOLE rest composition
    /// -- the leader plus the farthest echo's rest offset -- rather than on
    /// the leader's own raw path bounds. `make-icon.swift` centres the
    /// leader alone and then nudges it by two fixed fractions to rebalance
    /// the squircle around the icon's own trail direction; those fractions
    /// were tuned to that squircle's margins and do not carry to an
    /// arbitrary pane, so this derives the same idea (shift by half the
    /// echoes' extent) from `echoStepXFraction`/`echoStepYFraction` instead
    /// of a hand-picked constant. `dx`/`dy` land on top of that centred rest
    /// position. Rebuilt per call rather than cached: `CGPath` is not
    /// `Sendable`, so a stored one would need isolation this static API
    /// otherwise has no reason to carry.
    public static func path(in square: CGSize, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
        let base = HerdrRam.path()
        let bounds = base.boundingBoxOfPath
        let inset = square.width * insetFraction
        let body = CGRect(x: inset, y: inset, width: square.width - inset * 2, height: square.height - inset * 2)
        let margin = body.width * marginFraction
        let target = body.insetBy(dx: margin, dy: margin)
        let scale = target.height / bounds.height * heightFillFraction
        let maxBackSteps = CGFloat(echoCount)
        let compositeOffsetX = target.width * echoStepXFraction * maxBackSteps
        let compositeOffsetY = target.height * echoStepYFraction * maxBackSteps
        var transform = CGAffineTransform(
            translationX: target.midX - compositeOffsetX / 2 - bounds.midX * scale + dx,
            y: target.midY - compositeOffsetY / 2 + bounds.midY * scale + dy
        ).scaledBy(x: scale, y: -scale)
        return base.copy(using: &transform) ?? base
    }

    /// An echo's offset from the leader at animation `progress` (0 fully
    /// separated at rest, 1 merged with the leader). Steps back at the SAME
    /// scale as the leader: scaling an echo down would read as a smaller
    /// animal standing farther away rather than the same animal a moment
    /// earlier.
    public static func offset(restBackSteps: CGFloat, in square: CGSize, progress: Double) -> CGSize {
        let remaining = 1 - progress
        return CGSize(
            width: square.width * echoStepXFraction * restBackSteps * remaining,
            height: square.height * echoStepYFraction * restBackSteps * remaining
        )
    }
}
