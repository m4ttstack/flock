import CoreGraphics

/// A pane box's own chrome around its terminal surface: padding on every side
/// and a title row above the surface. Every value is a whole point, which is
/// what keeps the surface's origin on the device-pixel grid the box was
/// snapped to.
public enum PaneChrome {
    public static let verticalPadding: CGFloat = 4
    public static let horizontalPadding: CGFloat = 13
    public static let titleRowTop: CGFloat = 13
    public static let titleRowHeight: CGFloat = 22
    /// Holds the chat chip's overhang below the title row, the status line
    /// as far under the chip as the box's edge is above it, and room before
    /// the first terminal row.
    public static let titleGap: CGFloat = 19
    /// Every rounded shape drawn over or beside a box (drop preview, landing
    /// flash, ghost, toasts) takes this too, so an overlay's corners trace
    /// the box it lands on.
    public static let cornerRadius: CGFloat = ChromeRadius.surface

    /// From the box's top edge down to the first terminal row. This band is
    /// also the pane's at-rest drag handle, so it costs no terminal rows.
    public static var contentTop: CGFloat { titleRowTop + titleRowHeight + titleGap }

    /// Everything a box holds besides its surface, per axis: what is taken off
    /// a box before deriving its whole-cell grid.
    public static var size: CGSize { size(flush: false) }

    /// A pane with no agent in it (a shell) gets a compact header: its title
    /// row, the rule under it and little else. An agent arriving grows it.
    public static func isCompact(agent: String?) -> Bool { agent == nil }

    /// The panes in a layout that get the compact header: a shell's, unless a
    /// pane whose box starts at the same top edge carries a full one, so the
    /// title rows across a row line up.
    public static func compactPanes(_ panes: [(id: PaneID, agent: String?, top: CGFloat)]) -> Set<PaneID> {
        let fullTops = panes.filter { !isCompact(agent: $0.agent) }.map(\.top)
        return Set(panes.filter { pane in
            isCompact(agent: pane.agent) && !fullTops.contains { abs($0 - pane.top) < rowTolerance }
        }.map(\.id))
    }

    /// Box tops a snap or an odd gutter split can leave apart within a row.
    static let rowTolerance: CGFloat = 1

    public static let compactTitleRowTop: CGFloat = 6
    /// Under the compact header's rule, before the first terminal row.
    public static let compactGapBelowRule: CGFloat = 6

    public static func titleRowTop(compact: Bool) -> CGFloat { compact ? compactTitleRowTop : titleRowTop }

    /// Twice the title row's centre: the rule (or status line) sits as far
    /// under the row as the box's top edge is above it.
    public static func statusLineTop(compact: Bool) -> CGFloat {
        (titleRowTop(compact: compact) + titleRowHeight / 2) * 2
    }

    public static func contentTop(compact: Bool) -> CGFloat {
        compact ? statusLineTop(compact: true) + compactGapBelowRule : contentTop
    }

    public static func size(flush: Bool, compact: Bool) -> CGSize {
        CGSize(width: horizontalPadding(flush: flush) * 2, height: contentTop(compact: compact) + bottomPadding(flush: flush))
    }

    /// A pane running Claude Code sits nearly flush: it draws its own input
    /// rules and indents, so only a sliver of side padding and none at the
    /// bottom. The header keeps its room either way.
    public static func isFlush(agent: String?) -> Bool { agent == "claude" }

    public static func size(flush: Bool) -> CGSize {
        CGSize(width: horizontalPadding(flush: flush) * 2, height: contentTop + bottomPadding(flush: flush))
    }

    public static func horizontalPadding(flush: Bool) -> CGFloat { flush ? flushSidePadding : horizontalPadding }

    /// A sliver, not zero: the agent's input rules still run nearly full
    /// width, but its output does not touch the pane's edge.
    public static let flushSidePadding: CGFloat = 6

    public static func bottomPadding(flush: Bool) -> CGFloat { flush ? 0 : verticalPadding }
}
