import FlockCore
import SwiftUI

/// The title bar's Workspaces | Overview | Arrange tabs.
struct ViewTabBar: View {
    let theme: Theme
    var blockedCount = 0
    /// Per tab, for renders.
    var forced: [ViewTab: ControlInteraction] = [:]
    /// Off in the one-row title bar, where the tab strip needs the room; the
    /// help tag still names each view.
    var showsTitles = true

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode

    private var navigator: ViewTabNavigator { ViewTabNavigator(drag: drag, mode: mode) }

    var body: some View {
        let selected = navigator.selected
        let inert = navigator.dragInFlight
        HStack(spacing: ChromeMetrics.TitleBar.tabGap) {
            ForEach(ViewTab.allCases, id: \.self) { tab in
                ViewTabButton(
                    theme: theme, tab: tab, isSelected: tab == selected, hoverEnabled: !inert,
                    badge: tab == .overview && selected != .overview ? blockedCount : 0, forced: forced[tab],
                    showsTitle: showsTitles
                ) { navigator.choose(tab) }
            }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(!inert)
    }
}

struct ViewTabButton: View {
    let theme: Theme
    let tab: ViewTab
    let isSelected: Bool
    var hoverEnabled = true
    /// Needs-you cards waiting, on Overview's tab; none drawn at zero.
    var badge = 0
    var forced: ControlInteraction?
    var showsTitle = true
    let action: () -> Void

    private static let shape = AnyShape(RoundedRectangle(cornerRadius: ChromeMetrics.TitleBar.tabRadius))

    var body: some View {
        GridControlButton(
            theme: theme, shape: Self.shape,
            restFill: isSelected ? theme.lift : .clear,
            restForeground: isSelected ? theme.textStrong : theme.textLabel,
            hoverEnabled: hoverEnabled, forced: forced, action: action
        ) {
            HStack(spacing: ChromeMetrics.TitleBar.tabGlyphGap) {
                // An explicit square rather than a font glyph: a glyph's
                // layout box carries the font's descent and sits the drawing
                // low.
                ViewTabGlyph(tab: tab)
                    .frame(width: ChromeMetrics.TitleBar.tabGlyphSize, height: ChromeMetrics.TitleBar.tabGlyphSize)
                    .foregroundStyle(isSelected ? theme.textStrong : theme.textLabel)
                if showsTitle {
                    Text(tab.title)
                        .font(ChromeType.viewTab(selected: isSelected))
                }
                if badge > 0 {
                    Text("\(badge)")
                        .font(ChromeType.viewTabBadge)
                        .foregroundStyle(theme.red)
                        .padding(.horizontal, ChromeMetrics.TitleBar.badgeHorizontalPadding)
                        .frame(minWidth: ChromeMetrics.TitleBar.badgeHeight, minHeight: ChromeMetrics.TitleBar.badgeHeight)
                        .background(theme.red.opacity(ChromeMetrics.TitleBar.badgeFillOpacity), in: Capsule())
                        .accessibilityLabel("\(badge) blocked")
                }
            }
            .padding(.horizontal, showsTitle ? ChromeMetrics.TitleBar.tabHorizontalPadding : ChromeMetrics.TitleBar.iconTabHorizontalPadding)
            .frame(height: ChromeMetrics.TitleBar.tabHeight)
        }
        .background(WindowDragExclusion())
        .help("\(tab.title) (\(ShortcutLabel.text(key: ViewCommand.show(tab).key, modifiers: ViewCommand.show(tab).modifiers)))")
        .accessibilityIdentifier("flock.titleBar.tab.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
