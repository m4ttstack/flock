import FlockCore
import SwiftUI

extension ChromeMetrics {
    /// The launcher along a terminal pane's bottom edge. Its fills are one
    /// treatment at three strengths, so hover and press read as the same key
    /// waking up rather than as something new appearing.
    enum LauncherStrip {
        static let height: CGFloat = 42
        static let itemSpacing: CGFloat = 24
        static let keyLabelSpacing: CGFloat = 8
        static let keyWidth: CGFloat = 30
        static let keyHeight: CGFloat = 22
        static let keyCornerRadius: CGFloat = ChromeRadius.control
        static let keyGlyphSpacing: CGFloat = 1
        static let textSize: CGFloat = 12
        static let commandGlyphSize: CGFloat = 11
        static let titleSpacing: CGFloat = 16
        static let boltSize: CGFloat = 9
        static let boltSpacing: CGFloat = 6
        static let dividerWidth: CGFloat = 1
        static let dividerHeight: CGFloat = 16
        static let riseDuration: Double = 0.25
        static let dismissFade: Double = 0.1
        static let reducedMotionFade: Double = 0.15

        /// How far the band sits off the terminal ground: enough to read as an
        /// edge of the pane in a large window.
        static let bandTint: Double = 0.08
        static let darkLit = ChromeMetrics.Launcher.darkLabel
        static let lightLit = RGB(0x2C, 0x2D, 0x36)
        /// How far resting text sits from the band toward the lit color, which
        /// holds it near 4.5:1 on any theme's ground.
        static let darkInkMix: Double = 0.6
        static let lightInkMix: Double = 0.74
        /// A step under the items' ink: the title labels them, it is not one.
        static let darkTitleMix: Double = 0.58
        static let darkDividerOpacity: Double = 0.12
        static let lightDividerOpacity: Double = 0.15

        static let darkKeyFill: [Double] = [0.05, 0.13, 0.2]
        static let darkKeyEdge: [Double] = [0.08, 0.22, 0.34]
        static let lightKeyFill: [Double] = [0.4, 0.75, 1]
        static let lightKeyEdge: [Double] = [0.2, 0.3, 0.42]
    }
}
