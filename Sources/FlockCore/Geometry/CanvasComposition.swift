/// What a tab's canvas draws: every pane of the tab, tiled by its splits, or
/// the single pane herdr's zoom is holding open.
///
/// herdr's zoom is a view state, not a layout one, and the two halves of its
/// API disagree about it on purpose. `pane.layout` keeps listing every pane of
/// a zoomed tab at its unzoomed split rect, splits included, with only
/// `zoomed` to say otherwise: `pane_layout_snapshot`
/// (`herdr/src/app/api/panes.rs`) never consults `tab.zoomed`. herdr's own
/// renderer takes a different branch entirely:
/// `compute_pane_infos_for_tab` and `resize_tab_panes`
/// (`herdr/src/ui/panes.rs`) return exactly one pane, `tab.layout.focused()`,
/// over the whole tab area, and resize only that pane's runtime. flock
/// shares one session with that renderer, so the canvas follows the renderer:
/// a rect list is what a zoom is defined against, not what it shows.
public enum CanvasComposition: Equatable, Sendable {
    /// Every pane at its own split rect, with the dividers between them.
    case tiled
    /// One pane over the tab's whole area, and no dividers: there is no
    /// visible boundary left for one to move.
    case zoomed(PaneID)

    /// Reads the tab's OWN focus field rather than the session's focused pane:
    /// a zoom holds open the pane herdr's tab layout is focused on, which for
    /// a tab the window is showing but herdr is not focused on is not the
    /// session's focused pane at all. `focusedPane`'s first-pane fallback is
    /// deliberately not used -- it is a mutation-target rule, and applying it
    /// here would zoom an arbitrary pane onto the whole canvas.
    public static func of(layout: LayoutSnapshot) -> CanvasComposition {
        guard layout.zoomed,
              let held = layout.focusedPaneID,
              layout.panes.contains(where: { $0.paneID == held })
        else { return .tiled }
        return .zoomed(held)
    }

    /// The pane the zoom is holding open, `nil` while the tab is tiled: what
    /// a pane cell reads to decide whether it wears the zoom badge, so the
    /// badge and the pane that actually fills the canvas can never disagree.
    public var zoomedPaneID: PaneID? {
        switch self {
        case .tiled: nil
        case .zoomed(let pane): pane
        }
    }
}
