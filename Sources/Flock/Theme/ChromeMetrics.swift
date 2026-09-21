import CoreGraphics
import FlockCore

/// The window chrome's fixed dimensions, shared by the SwiftUI chrome and the
/// AppKit title bar so the window buttons center on the same bar the views
/// draw. The chrome is designed on a 1x frame and rendered at 1.28x: every
/// value is the design's scaled and rounded to a whole point, which keeps
/// surfaces and boxes on the pixel grid, except rules and borders, which stay
/// 1pt. `PaneChrome` and `DividerBand` hold the pane and gutter values at the
/// same scale, and `ChromeType` the text.
enum ChromeMetrics {
    static let ruleWidth: CGFloat = 1

    /// The two resting status shapes, as fractions of whatever size the dot is
    /// asked for rather than fixed points: the same rule has to read at 4pt on
    /// a grid mini pane and at 8pt on a rail row. Herdglass derives its own
    /// insets the same way and for the same reason.
    static let statusRingStrokeRatio: CGFloat = 0.25
    static let statusUnknownRatio: CGFloat = 0.5

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
        /// The rail's own width is the user's, and lives in
        /// `FlockCore.RailWidth` with the bounds it is kept inside.
        ///
        /// How much of the rail's trailing edge grabs that width. Inside the
        /// rail, over the gutter its rows already leave clear, so it covers
        /// nothing a row draws.
        static let resizeGrabWidth: CGFloat = 10
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
        /// A step up from the strip's 6pt dot, which the parity checklist
        /// asks for on the rail and the pane header: this is the one mark a
        /// workspace nobody is looking at has, and it has to survive being
        /// read from across the room rather than from the caret.
        static let statusDot: CGFloat = 8
        /// The bar herdr's focused tab is marked with inside a grid
        /// thumbnail. Was the rail's indicator too, until the rail's became a
        /// status dot; the thumbnail keeps it, because there it marks focus
        /// and the tab's own status dot sits beside it.
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
        /// lines rather than points. Tabs are drawn to their titles, so there
        /// is no single tab width to step by: the narrowest one is what a
        /// strip of short names steps by exactly, and the only step that can
        /// never carry the strip past a tab it has not shown yet.
        static let wheelLineStep: CGFloat = TabWidth.minimum + tabGap
    }

    /// A tab's own width is its title's, and lives in `FlockCore.TabWidth`
    /// with the bounds it is kept inside; `TabSizing` takes the measurement
    /// that rule is given.
    enum Tab {
        static let height: CGFloat = 28
        static let horizontalPadding: CGFloat = 12
        static let labelDotGap: CGFloat = 6
        static let statusDot: CGFloat = 6
        static let underlineHeight: CGFloat = 3
        /// The status dot and the hover close stand in the same place, one at
        /// a time, so the room kept for them is the wider of the two. Kept as
        /// a slot rather than as the close's own size because what the tab
        /// reserves is a place, not a control.
        static var trailingSlot: CGFloat { max(statusDot, CloseButton.size) }
    }

    enum Canvas {
        static let margin: CGFloat = 6
    }

    /// The inline rename editor, wherever it opens (pane legend, tab, rail
    /// row). It stands in the label's own place, so it takes the label's
    /// padding and its host's row height rather than a box of its own.
    enum Rename {
        static let horizontalPadding: CGFloat = 5
        static let cornerRadius: CGFloat = 3
        /// Narrow enough for a rail row, wide enough that a two-word name is
        /// not scrolling as it is typed.
        static let minimumWidth: CGFloat = 72
        /// The pane's editor stands in an overlay on the legend, which gives
        /// it the whole box's width unless something caps it; a field running
        /// the length of the pane reads as a search bar, not a rename. The
        /// tab and rail editors need no cap: their rows already are one.
        static let paneWidth: CGFloat = 160
    }

    /// The hover-reveal close control on a tab and an attention toast.
    enum CloseButton {
        static let size: CGFloat = 18
        static let cornerRadius: CGFloat = 3
        static let symbol: CGFloat = 11
    }

    enum Pane {
        static let scrollIndicatorWidth: CGFloat = 5
        static let scrollIndicatorInset: CGFloat = 4
        /// The status chip's own text inset. Kept apart from `legendItemGap`
        /// below: the two happened to share one constant, so widening this
        /// one for the chip's text also widened the gap before the chip.
        static let statusChipPadding: CGFloat = 8
        /// The legend's trailing row: the gap between the zoom badge, the
        /// chat button and the status chip, none of which is the chip's own
        /// inset.
        static let legendItemGap: CGFloat = 5
        static let toastInset: CGFloat = 13
    }

    /// The pane legend's chat trigger, also the state it shows: signed in
    /// carries the handle, the glyph and (when there is unread) a count;
    /// signed out shows the glyph alone; chat unavailable on this machine
    /// draws no button at all.
    enum ChatButton {
        /// The signed-in button's only fixed dimension. Its width is
        /// whatever the handle, the glyph and (when present) the count add
        /// up to: a count that only sometimes shows must not leave a gap
        /// behind when it is absent.
        static let signedInHeight: CGFloat = 18
        static let signedOutSize = CGSize(width: 27, height: 17)
        static let cornerRadius: CGFloat = 4
        static let verticalPadding: CGFloat = 3
        static let horizontalPadding: CGFloat = 8
        static let gap: CGFloat = 6
        /// Height only. The width the canvas drew was 18pt, the width of the
        /// one handle it happened to contain, and pinning to it clipped any
        /// name that measured wider -- "nell" fits where "olga" does not,
        /// because two narrow `l`s are not four average characters. A name is
        /// never abbreviated, so the text sizes to itself and the button
        /// grows.
        static let handleHeight: CGFloat = 12
        static let iconSize = CGSize(width: 11, height: 11)
        /// Height only, for the same reason: the canvas drew a single digit.
        static let countHeight: CGFloat = 12
    }

    /// The chat button's popover: the plugin's launcher, six bands stacked
    /// with zero gap between them, each sized to its own row content rather
    /// than sharing one uniform inset. `signedOutHeight`/`signedInHeight` are
    /// each band's own height summed; a geometry test cross-checks the sum
    /// against these named totals so the two can never drift apart.
    enum ChatPopover {
        static let width: CGFloat = 360
        static let signedOutHeight: CGFloat = 325
        static let signedInHeight: CGFloat = 348
        static let cornerRadius: CGFloat = 10

        enum Header {
            static let height: CGFloat = 41
            static let verticalPadding: CGFloat = 12
            static let horizontalPadding: CGFloat = 14
            static let iconSize = CGSize(width: 15, height: 15)
        }

        /// The dot/handle/state-word row, then (signed in only) a room-chip
        /// row 38pt below the band's own top. That offset is `topPadding` +
        /// the main row's own height (the chip's 18) + `gap`, which is also
        /// this band's vertical gap to the room row -- one number serving
        /// both, per the canvas's own single gap token for this band.
        enum Status {
            static let heightSignedOut: CGFloat = 45
            static let heightSignedIn: CGFloat = 68
            static let topPadding: CGFloat = 13
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 14
            static let leadingPadding: CGFloat = 14
            static let gap: CGFloat = 7
            static let dotSize: CGFloat = 7
            static let paneChipSize = CGSize(width: 63, height: 18)
            static let paneChipCornerRadius: CGFloat = 4
            static let paneChipVerticalPadding: CGFloat = 3
            static let paneChipHorizontalPadding: CGFloat = 8
            static let paneChipGap: CGFloat = 5
            static let paneChipIconSize = CGSize(width: 10, height: 10)
            static let roomChipHeight: CGFloat = 16
            static let roomChipCornerRadius: CGFloat = 4
            static let roomChipVerticalPadding: CGFloat = 2
            static let roomChipHorizontalPadding: CGFloat = 7
            static let roomChipGap: CGFloat = 6
        }

        /// Shared by the FEATURES and THIS PANE section labels: 14 top, 14
        /// trailing, 7 bottom, 14 leading.
        enum SectionLabel {
            static let height: CGFloat = 33
            static let topPadding: CGFloat = 14
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 7
            static let leadingPadding: CGFloat = 14
        }

        /// Four rows, zero gap, exactly filling the band (4 x 31 = 124): the
        /// band's own padding is horizontal only (8 each side, matching each
        /// row's own narrower 344 width), never vertical.
        enum Features {
            static let bandHeight: CGFloat = 124
            static let horizontalInset: CGFloat = 8
            static let rowSize = CGSize(width: 344, height: 31)
            static let rowCornerRadius: CGFloat = 5
            static let rowHorizontalPadding: CGFloat = 8
            static let rowGap: CGFloat = 9
            static let iconSize = CGSize(width: 14, height: 14)
        }

        /// One button spanning the band's full inner width (360 - the 14pt
        /// insets on each side), zero top padding (the band sits flush under
        /// THIS PANE's own bottom padding), 16 clear below it to the
        /// popover's own bottom edge.
        enum SignButtons {
            static let bandHeight: CGFloat = 49
            static let topPadding: CGFloat = 0
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 16
            static let leadingPadding: CGFloat = 14
            static let buttonSize = CGSize(width: 332, height: 33)
            static let cornerRadius: CGFloat = 6
            static let buttonVerticalPadding: CGFloat = 9
            static let buttonHorizontalPadding: CGFloat = 10
            static let contentGap: CGFloat = 7
            static let iconSize = CGSize(width: 13, height: 13)
        }
    }

    /// The back-chevron/title/close header every chat sub-view (Peek, Quick
    /// send, Broadcast) opens with. One shared height and icon size; each
    /// view supplies its own width, since Broadcast is wider than the other
    /// two.
    enum ChatSubviewHeader {
        static let height: CGFloat = 41
        static let verticalPadding: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
        static let iconSize = CGSize(width: 14, height: 14)
        static let gap: CGFloat = 9
        /// The chevron/close glyph's own clickable box: `height - 2 *
        /// verticalPadding` is the whole band's own vertical lane, so this
        /// is the largest square hit target that fits without growing the
        /// header past its fixed 41pt total.
        static let iconHitSize: CGFloat = height - 2 * verticalPadding
        static let iconHitCornerRadius: CGFloat = 4
    }

    /// Chat peek: buddies with a jump affordance, then rooms, each carrying
    /// an unread pill. `signedInHeight`-style total is `height`, cross-checked
    /// by a geometry test against the sum of every band below the header.
    enum ChatPeek {
        static let width: CGFloat = 360
        static let height: CGFloat = 326
        static let cornerRadius: CGFloat = 10

        enum Label {
            static let height: CGFloat = 31
            static let topPadding: CGFloat = 13
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 6
            static let leadingPadding: CGFloat = 14
        }

        enum PaneRow {
            static let height: CGFloat = 42
            static let verticalPadding: CGFloat = 7
            static let horizontalPadding: CGFloat = 14
            static let gap: CGFloat = 9
            static let dotSize: CGFloat = 7
            static let stackGap: CGFloat = 1
            static let pillSize = CGSize(width: 19, height: 16)
            static let pillCornerRadius: CGFloat = 8
            static let pillVerticalPadding: CGFloat = 2
            static let pillHorizontalPadding: CGFloat = 6
            static let jumpIconSize = CGSize(width: 12, height: 12)
        }

        /// The first room row is 28pt, every one after it 27pt -- the only
        /// two heights the design names, for however many rooms there are.
        enum RoomRow {
            static let firstHeight: CGFloat = 28
            static let subsequentHeight: CGFloat = 27
            static let verticalPadding: CGFloat = 6
            static let horizontalPadding: CGFloat = 14
            static let gap: CGFloat = 9
        }
    }

    /// Chat quick send: one target chip selected at a time, a message field,
    /// and a send button naming the sender's own handle.
    enum ChatQuickSend {
        static let width: CGFloat = 360
        static let height: CGFloat = 234
        static let cornerRadius: CGFloat = 10

        enum TargetBand {
            /// The single-row height the canvas modelled -- still exactly
            /// right for however many chips fit one row; a target count that
            /// wraps grows past it, up to `maxVisibleRows`.
            static let height: CGFloat = 57
            static let topPadding: CGFloat = 13
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 4
            static let leadingPadding: CGFloat = 14
            static let gap: CGFloat = 7
            static let chipHeight: CGFloat = 21
            static let chipCornerRadius: CGFloat = 4
            static let chipVerticalPadding: CGFloat = 4
            static let chipHorizontalPadding: CGFloat = 9
            static let chipGap: CGFloat = 6
            /// Chips wrap onto further rows rather than compress, and the
            /// row gap reuses `chipGap`'s own rhythm rather than a value the
            /// canvas never modelled. Beyond this many rows the band scrolls
            /// instead of growing further, so a target list in the dozens
            /// can never make the popover taller than the screen.
            static let maxVisibleRows: Int = 3
            static var maxChipsHeight: CGFloat {
                let rows = CGFloat(maxVisibleRows)
                return rows * chipHeight + (rows - 1) * chipGap
            }
        }

        enum FieldBand {
            static let height: CGFloat = 136
            static let topPadding: CGFloat = 10
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 14
            static let leadingPadding: CGFloat = 14
            static let gap: CGFloat = 9
            static let fieldSize = CGSize(width: 332, height: 74)
            static let fieldCornerRadius: CGFloat = 6
            static let fieldVerticalPadding: CGFloat = 10
            static let fieldHorizontalPadding: CGFloat = 11
            static let footerHeight: CGFloat = 29
            static let sendButtonSize = CGSize(width: 82, height: 29)
            static let sendButtonCornerRadius: CGFloat = 6
            static let sendButtonVerticalPadding: CGFloat = 7
            static let sendButtonHorizontalPadding: CGFloat = 13
            static let sendButtonGap: CGFloat = 6
        }
    }

    /// Chat broadcast: the widest of the three sub-views, a checkbox per
    /// pane, and a `mauve` send button -- the one place it and Quick send's
    /// own `accent` button deliberately differ.
    enum ChatBroadcast {
        static let width: CGFloat = 400
        static let height: CGFloat = 370
        static let cornerRadius: CGFloat = 10

        enum SelectHead {
            static let height: CGFloat = 31
            static let topPadding: CGFloat = 13
            static let trailingPadding: CGFloat = 14
            static let bottomPadding: CGFloat = 6
            static let leadingPadding: CGFloat = 14
        }

        enum PaneRow {
            static let height: CGFloat = 42
            static let verticalPadding: CGFloat = 7
            static let horizontalPadding: CGFloat = 14
            static let gap: CGFloat = 10
            static let checkboxSize: CGFloat = 15
            static let checkboxCornerRadius: CGFloat = 3
            static let checkTickSize: CGFloat = 10
            static let dotSize: CGFloat = 7
            static let stackGap: CGFloat = 1
        }

        enum FieldBand {
            static let height: CGFloat = 130
            static let padding: CGFloat = 14
            static let gap: CGFloat = 9
            static let fieldSize = CGSize(width: 372, height: 64)
            static let fieldCornerRadius: CGFloat = 6
            static let fieldVerticalPadding: CGFloat = 10
            static let fieldHorizontalPadding: CGFloat = 11
            static let footerHeight: CGFloat = 29
            static let sendButtonSize = CGSize(width: 112, height: 29)
            static let sendButtonCornerRadius: CGFloat = 6
            static let sendButtonVerticalPadding: CGFloat = 7
            static let sendButtonHorizontalPadding: CGFloat = 13
            static let sendButtonGap: CGFloat = 6
        }
    }

    enum Card {
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 18
        static let lineHorizontalPadding: CGFloat = 13
        static let lineVerticalPadding: CGFloat = 5
    }

    /// The pane attach badge: the mark beside "flocking...", in the corner of
    /// a pane whose first frame is still outstanding.
    enum Loader {
        /// Between the mark and the word, which sit on one line.
        static let spacing: CGFloat = 8
        /// One fixed size at every pane size. The full-pane version this
        /// replaced scaled with the pane because it was the pane's whole
        /// content; a badge is furniture, and furniture that grows with its
        /// container stops reading as furniture.
        static let badgeMarkSize: CGFloat = 32
        /// From the pane's own inner edge. Matches nothing else deliberately:
        /// it is measured against the pane's rounded corner, which is what it
        /// has to clear.
        static let badgeInset: CGFloat = 12
    }

    enum NoHerdr {
        static let spacing: CGFloat = 14
        static let horizontalPadding: CGFloat = 60
        static let symbolSpacing: CGFloat = 6
        static let primaryActionTopPadding: CGFloat = 8
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
        /// Open space between a vendor mark and the edge of its badge, which
        /// OpenAI's terms for the Blossom ask for by name.
        static let markInset: CGFloat = 6
        /// Clears the prompt row a fresh shell prints above the launcher. It
        /// is measured against terminal rows, which the chrome scale leaves
        /// alone, so it is not scaled.
        static let promptClearance: CGFloat = 28
        /// How far the border brightens toward the accent under the pointer.
        /// The fill moving on its own reads as a shadow rather than a target,
        /// which is what these buttons looked like with no hover state at all.
        static let hoverBorderAccent: Double = 0.55
        /// Wash of accent over the fill while a press is held, the same value
        /// the rail's heading buttons use.
        static let pressedAccent: Double = 0.2
        static let pressedScale: CGFloat = 0.97
        static let hoverFade: Double = 0.12
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

    /// The top-right attention stack. Its own box rather than `Toast`'s: a
    /// notice is one line that leaves on its own, an attention toast is a
    /// two-line card that can be clicked, dismissed and stacked.
    enum AttentionToast {
        /// The hover card's width. Both are a detail card about one pane, and
        /// two widths for the same thing would read as two vocabularies.
        static let width: CGFloat = 274
        static let horizontalPadding: CGFloat = 13
        static let verticalPadding: CGFloat = 10
        static let dotSpacing: CGFloat = 9
        static let lineSpacing: CGFloat = 2
        static let stackSpacing: CGFloat = 8
        static let statusDot: CGFloat = 8
        /// herdr's dots glow when a pane is actually asking for something;
        /// the parity checklist carries it on `blocked` alone.
        static let blockedGlowRadius: CGFloat = 6
        static let trailingGlyphWidth: CGFloat = 20
        static let pillHorizontalPadding: CGFloat = 9
        static let pillVerticalPadding: CGFloat = 4
        static let shadowRadius: CGFloat = 12
        static let shadowY: CGFloat = 5
        /// How often the finished toasts are checked against their six
        /// seconds. Fine enough that a toast never visibly outstays it,
        /// coarse enough to be free; it runs only while one is up.
        static let sweepInterval: Duration = .milliseconds(250)
        static let borderOpacity: Double = 0.45
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
        /// Between the pane and the card beside it: wide enough to read as
        /// two things, short enough for the pointer to cross it well inside
        /// `AllWorkspacesGridState.hoverCardGrace`.
        static let paneGap: CGFloat = 8
        /// The tail's lines sit at the terminal's own rhythm, tighter than the
        /// card's rows, so a screenful reads as one block of output.
        static let tailLineSpacing: CGFloat = 1
        static let copySpacing: CGFloat = 4
        static let copyHorizontalPadding: CGFloat = 6
        static let copyVerticalPadding: CGFloat = 3
        static let copyCornerRadius: CGFloat = 3
        /// Where placement starts before the card has measured itself once:
        /// a card with a full tail, since that is what nearly every card
        /// settles at.
        static let estimatedHeight: CGFloat = 220
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
