import FlockCore
import SwiftUI

/// The app's own mark, drawn as vector paths: the ram and its three-echo
/// trail, the same four fills `Scripts/make-icon.swift` paints into the app
/// icon.
///
/// One view rather than a copy per surface, because a second copy of this
/// drifts from the icon the moment either is touched. `progress` is what the
/// attach badge animates; everything else passes `nil` and gets the resting
/// composition, echoes fully spread.
///
/// The colours are `HerdrRamTrail.Colors` and never come from the active
/// theme. This is a logo: it has to read as the same animal under every pane
/// theme, the way the app icon does not repaint itself. Sourcing them from
/// `ThemePalette` was tried and reverted, because a theme with a green or
/// orange accent turned the ram into a different mark entirely.
struct HerdrRamMark: View {
    let size: CGFloat
    /// An echo's own start delay to how merged it is right now, 0 resting and
    /// 1 merged with the leader. `nil` is the resting composition.
    var progress: ((Double) -> Double)?

    private var square: CGSize { CGSize(width: size, height: size) }

    var body: some View {
        ZStack {
            ForEach(Array(HerdrRamTrail.echoes.enumerated()), id: \.offset) { index, echo in
                let merge = progress?(echo.startDelay) ?? 0
                let offset = HerdrRamTrail.offset(restBackSteps: echo.restBackSteps, in: square, progress: merge)
                Path(HerdrRamTrail.path(in: square))
                    .fill(Color(HerdrRamTrail.Colors.echoes[index]))
                    .opacity(echo.restOpacity - PaneLoaderChoreography.mergeOpacityDrop * merge)
                    .offset(x: offset.width, y: offset.height)
            }
            Path(HerdrRamTrail.path(in: square))
                .fill(Color(HerdrRamTrail.Colors.leader))
        }
        .frame(width: size, height: size)
        // `HerdrRamTrail.path` is fit the way `make-icon.swift` fits it into a
        // bottom-left-origin, y-up `CGContext`; SwiftUI's own `Path` space is
        // top-left-origin, y-down, so this is the one place that reconciles
        // the two rather than the shared geometry carrying a SwiftUI-specific
        // flip.
        .scaleEffect(x: 1, y: -1)
        .accessibilityHidden(true)
    }
}
