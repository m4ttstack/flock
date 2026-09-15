import CoreGraphics

/// The window chrome's fixed dimensions, shared by the SwiftUI chrome and the
/// AppKit title bar so the window buttons center on the same bar the views
/// draw. The chrome is designed on a 1x frame and rendered at 1.28x: every
/// value is the design's scaled and rounded to a whole point, which keeps
/// surfaces and boxes on the pixel grid, except rules and borders, which stay
/// 1pt. `PaneChrome` and `DividerBand` hold the pane and gutter values at the
/// same scale, and `ChromeType` the text.
enum ChromeMetrics {
    static let ruleWidth: CGFloat = 1

    enum TitleBar {
        static let height: CGFloat = 26
        static let noticeSpacing: CGFloat = 6
        static let noticeDot: CGFloat = 6
        static let noticeTrailingPadding: CGFloat = 13
        /// The design sets the title 1.5pt below the bar's center; the inset
        /// is twice that because the frame centers the padded label.
        static let titleTopInset: CGFloat = 3
    }

    enum Banner {
        static let spacing: CGFloat = 10
        static let horizontalPadding: CGFloat = 15
        static let verticalPadding: CGFloat = 8
    }

    enum Rail {
        static let width: CGFloat = 192
        static let verticalPadding: CGFloat = 13
        static let horizontalPadding: CGFloat = 10
        static let rowGap: CGFloat = 1
        static let headingGap: CGFloat = 8
        /// The heading's bottom to the first row's top: the heading gap with a
        /// row gap either side of it.
        static let headingToFirstRow: CGFloat = rowGap + headingGap + rowGap
    }

    enum WorkspaceRow {
        static let contentHeight: CGFloat = 17
        static let verticalPadding: CGFloat = 5
        static let horizontalPadding: CGFloat = 10
        static let spacing: CGFloat = 8
        static let countMinimumGap: CGFloat = 5
        static let cornerRadius: CGFloat = 3
        static let indicatorSize = CGSize(width: 3, height: 15)
    }

    enum Strip {
        static let height: CGFloat = 36
        static let horizontalPadding: CGFloat = 10
        static let tabGap: CGFloat = 3
        /// The design sets the protocol readout 1.5pt above the strip's
        /// center; the inset is twice that because the frame centers the
        /// padded label.
        static let readoutBottomInset: CGFloat = 3
    }

    enum Tab {
        static let size = CGSize(width: 100, height: 28)
        static let horizontalPadding: CGFloat = 12
        static let labelDotGap: CGFloat = 6
        static let statusDot: CGFloat = 6
        static let underlineHeight: CGFloat = 3
    }

    enum Canvas {
        static let margin: CGFloat = 6
    }

    enum Pane {
        static let scrollIndicatorWidth: CGFloat = 5
        static let scrollIndicatorInset: CGFloat = 4
        static let statusChipPadding: CGFloat = 5
        static let toastInset: CGFloat = 13
    }

    enum Card {
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 18
        static let lineHorizontalPadding: CGFloat = 13
        static let lineVerticalPadding: CGFloat = 5
    }

    enum Launcher {
        static let spacing: CGFloat = 13
        static let buttonSpacing: CGFloat = 15
        static let labelSpacing: CGFloat = 10
        static let buttonHorizontalPadding: CGFloat = 18
        static let buttonVerticalPadding: CGFloat = 13
        static let hintHorizontalPadding: CGFloat = 20
        static let hintBottomPadding: CGFloat = 10
        static let monogram: CGFloat = 28
        /// Clears the prompt row a fresh shell prints above the launcher. It
        /// is measured against terminal rows, which the chrome scale leaves
        /// alone, so it is not scaled.
        static let promptClearance: CGFloat = 28
    }

    enum Toast {
        static let topGap: CGFloat = 13
        static let trailingInset: CGFloat = 18
        static let spacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 13
        static let verticalPadding: CGFloat = 8
        static let copiedVerticalPadding: CGFloat = 6
        static let shadowRadius: CGFloat = 12
        static let shadowY: CGFloat = 5
        static let copiedShadowY: CGFloat = 8
    }

    enum Ghost {
        /// The floor for a proxy whose origin is tiny (a tab, a rail row), so
        /// the label always has somewhere to sit.
        static let minimumSize = CGSize(width: 192, height: 41)
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 8
        static let shadowRadius: CGFloat = 18
        static let shadowY: CGFloat = 10
    }

    enum RatioLabel {
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 3
        static let clearanceAlongHandle: CGFloat = 18
        static let clearanceAboveHandle: CGFloat = 20
    }
}
