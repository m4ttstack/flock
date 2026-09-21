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

    /// Breathing room around the whole composition. The icon's own fit
    /// instead chains two much larger insets (a squircle inset, then a
    /// margin inside it) because the ram has to sit inside a rounded ground
    /// with visible shoulder on every side. A pane has no ground, so
    /// carrying those over just made the ram small in the middle of a lot of
    /// nothing.
    private static let marginFraction: CGFloat = 0.03
    private static let echoStepXFraction: CGFloat = 0.105
    private static let echoStepYFraction: CGFloat = 0.075

    /// The leader ram, positioned so that the WHOLE rest composition -- the
    /// leader plus the farthest echo's rest offset -- both fits `square` and
    /// is centred in it. Sizing and centring on the leader alone is the
    /// mistake to avoid: the echoes extend up and to the right of it by a
    /// third of the square, so a leader-centred mark reads as sitting high
    /// and right of the middle, and a leader-sized one pushes the farthest
    /// echo out of frame.
    ///
    /// The spread is measured against `square`, the same basis `offset` uses
    /// for the offsets actually applied to those echoes. Measuring it
    /// against any inset box under-corrects by exactly the ratio between
    /// them. `dx`/`dy` land on top of the centred rest position. Rebuilt per
    /// call rather than cached: `CGPath` is not `Sendable`, so a stored one
    /// would need isolation this static API otherwise has no reason to
    /// carry.
    public static func path(in square: CGSize, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
        let base = HerdrRam.path()
        let bounds = base.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return base }
        let available = CGRect(origin: .zero, size: square)
            .insetBy(dx: square.width * marginFraction, dy: square.height * marginFraction)
        let spread = offset(restBackSteps: CGFloat(echoCount), in: square, progress: 0)
        let scale = min(
            (available.width - spread.width) / bounds.width,
            (available.height - spread.height) / bounds.height
        )
        guard scale > 0 else { return base }
        var transform = CGAffineTransform(
            translationX: available.midX - spread.width / 2 - bounds.midX * scale + dx,
            y: available.midY - spread.height / 2 + bounds.midY * scale + dy
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
