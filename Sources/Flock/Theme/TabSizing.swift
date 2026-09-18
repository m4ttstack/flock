import AppKit
import FlockCore

/// The window strip's tabs, sized to the titles they hold. The rule is
/// `FlockCore.TabWidth`, with the bounds a tab is kept inside; what lives here
/// is the measurement it takes, which needs the real face.
enum TabSizing {
    static func width(of title: String) -> CGFloat {
        TabWidth.fitting(
            titleWidth: titleWidth(title),
            horizontalPadding: ChromeMetrics.Tab.horizontalPadding,
            labelDotGap: ChromeMetrics.Tab.labelDotGap,
            trailingSlot: ChromeMetrics.Tab.trailingSlot
        )
    }

    /// Measured in the face a SELECTED tab is set in, whatever state the tab
    /// is in: the label is Inter Medium while selected and Regular while not,
    /// so a tab measured in its own state would widen as the selection reached
    /// it and carry every tab after it along the strip.
    private static func titleWidth(_ title: String) -> CGFloat {
        let weight = ChromeType.tabLabelWeight(selected: true)
        // A face that failed to register draws in the system face, so a
        // measure that fell back anywhere else would size the tab for a width
        // nothing draws at.
        let font = NSFont(name: weight.postScriptName, size: ChromeType.tabLabelSize)
            ?? .systemFont(ofSize: ChromeType.tabLabelSize)
        return (title as NSString).size(withAttributes: [.font: font]).width
    }
}
