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
        /// The "All workspaces" button's hit box, overlaid on the heading row
        /// so its size never moves the heading or the rows below it. Taller
        /// than the heading text: the overflow is absorbed by the padding
        /// above and the gap below.
        static let headingButtonSize: CGFloat = 22
        static let headingButtonCornerRadius: CGFloat = 3
        /// How much accent a held press blends over the selection fill, so
        /// pressed reads a step deeper than hover.
        static let headingButtonPressedAccent: Double = 0.2
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
        /// How far the overflow hint runs in from an edge that hides tabs.
        static let edgeFadeWidth: CGFloat = 24
        /// What one notch of a classic wheel is worth, whose delta counts
        /// lines rather than points: one tab and the gap after it, so a notch
        /// advances the strip by exactly one tab.
        static let wheelLineStep: CGFloat = Tab.size.width + tabGap
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

    enum Grid {
        static let headerHeight: CGFloat = 36
        static let headerHorizontalPadding: CGFloat = 13
        static let headerSpacing: CGFloat = 8
        static let canvasPadding: CGFloat = 13
        /// Between cards, across a row and down the grid.
        static let cardGap: CGFloat = 13
        static let cardCornerRadius: CGFloat = 3
        static let cardVerticalPadding: CGFloat = 10
        static let cardHorizontalPadding: CGFloat = 13
        static let cardSpacing: CGFloat = 10
        static let cardHeaderSpacing: CGFloat = 8
        static let cardStatusDot: CGFloat = 6
        /// Between tabs, across a row and down an expanded card.
        static let tabGap: CGFloat = 10
        static let tabLabelGap: CGFloat = 5
        /// The thumbnail carries the tab's own title strip, so it is taller
        /// than the block alone by exactly what the label row under it used
        /// to spend: a card's rows are the same height either way.
        static let thumbnailHeight: CGFloat = 101
        /// How wide a thumbnail is drawn, at every window size: a miniature
        /// that stretches with the window stops reading as one, and a card's
        /// row buys or loses slots instead. Thumbnails, the tile and the
        /// new-tab placeholder all take it.
        ///
        /// Wide enough to read as a tab rather than a sliver, which costs the
        /// narrowest window the app allows (900pt) a slot: it holds three of
        /// these where it held four of the 93.625pt slot the design draws at
        /// that width. 93 is the widest that would have kept four, and the
        /// cost of keeping it is a thumbnail too narrow to read.
        static let thumbnailWidth: CGFloat = 120
        /// The most slots a card's row is ever divided into, however wide the
        /// window. Width alone would lay seven or more across a 2000pt window
        /// in one line; past four the card stops reading as a card, so the
        /// extra width wraps the tabs instead of stretching the row.
        static let maxTabsPerRow = 4
        /// The tab's handle: a band across the top of its thumbnail, holding
        /// the title and status dot.
        static let tabStripHeight: CGFloat = 15
        static let tabStripHorizontalPadding: CGFloat = 5
        static let tabStripSpacing: CGFloat = 5
        /// herdr's focused tab is marked the way the rail marks its focused
        /// workspace: the same bar, holding the same share of the row it sits
        /// in.
        static let tabStripIndicatorSize = CGSize(
            width: WorkspaceRow.indicatorSize.width,
            height: (tabStripHeight * WorkspaceRow.indicatorSize.height / WorkspaceRow.contentHeight).rounded()
        )
        static let thumbnailCornerRadius: CGFloat = 3
        static let thumbnailPadding: CGFloat = 4
        static let miniPaneGap: CGFloat = 4
        static let miniPaneCornerRadius: CGFloat = 1
        static let miniPaneVerticalPadding: CGFloat = 4
        static let miniPaneHorizontalPadding: CGFloat = 5
        static let miniPaneTitleSpacing: CGFloat = 3
        static let miniPaneStatusDot: CGFloat = 4
        static let labelStatusDot: CGFloat = 6
    }

    enum HoverCard {
        static let width: CGFloat = 274
        static let verticalPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 13
        static let spacing: CGFloat = 5
        static let cornerRadius: CGFloat = 4
        static let titleSpacing: CGFloat = 6
        static let statusDot: CGFloat = 6
        /// Right of and below the pointer, clear of the arrow cursor.
        static let pointerOffset = CGSize(width: 13, height: 18)
        /// Where placement starts before the card has measured itself once.
        static let estimatedHeight: CGFloat = 110
    }

    enum Ghost {
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 8
        static let compactPadding: CGFloat = 6
        static let compactSpacing: CGFloat = 6
        /// Narrower than this and a compact proxy carries its glyph alone: the
        /// proxy is sized from the item it stands for, so it is never widened
        /// to fit a label.
        static let compactLabelMinimumWidth: CGFloat = 64
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
