import FlockCore
import SwiftUI

/// A folding rail section's header: its mark, its name in the rail's heading
/// style, and a chevron after the name saying which way it is folded, with
/// whatever the section reports held at the trailing edge. The whole row is
/// the toggle.
struct RailSectionHeader<Mark: View, Trailing: View>: View {
    let theme: Theme
    let title: String
    let isCollapsed: Bool
    let accessibilityIdentifier: String
    let toggle: () -> Void
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: ChromeMetrics.RailSection.headerChevronGap) {
                mark()
                Text(title)
                    .font(ChromeType.railHeading)
                    .tracking(ChromeType.railHeadingTracking)
                    .fixedSize()
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(ChromeType.railSectionChevron)
                    .frame(width: ChromeMetrics.RailSection.headerChevron)
                Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
                trailing()
            }
            .foregroundStyle(theme.textLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, ChromeMetrics.Rail.headingGap)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
    }
}
