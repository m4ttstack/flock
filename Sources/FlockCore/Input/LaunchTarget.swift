/// The pane ⌘1 and on, and the palette's launch rows, type into: the canvas's
/// focused pane, unless herdr has detected an agent there, whose prompt is not
/// a shell's. Deliberately blind to whether the pane shows the launcher: that
/// ends at the first keystroke or redraw, long before a shell stops taking a
/// command. Whether the shell is at its prompt is asked of herdr as the launch
/// fires (`SessionViewModel.isAtPrompt`), never decided here.
public enum LaunchTarget {
    public static func pane(canvasPane: PaneID?, agent: String?) -> PaneID? {
        agent == nil ? canvasPane : nil
    }
}
