import FlockCore
import SwiftUI

/// The title bar's Workspaces | Overview | Arrange tabs.
struct ViewTabBar: View {
    let theme: Theme
    var blockedCount = 0
    /// Per tab, for renders.
    var forced: [ViewTab: ControlInteraction] = [:]

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode

    private var navigator: ViewTabNavigator { ViewTabNavigator(drag: drag, mode: mode) }

    var body: some View {
        let selected = navigator.selected
        let inert = navigator.dragInFlight
        HStack(spacing: 0) {
            ForEach(ViewTab.allCases, id: \.self) { tab in
                ViewTabButton(
                    theme: theme, tab: tab, isSelected: tab == selected, hoverEnabled: !inert,
                    badge: tab == .overview && selected != .overview ? blockedCount : 0, forced: forced[tab]
                ) { navigator.choose(tab) }
            }
        }
        // The viewer's tabs: flat cells the bar's full height, ruled apart.
        .overlay(alignment: .leading) { rule }
        .allowsHitTesting(!inert)
    }

    private var rule: some View {
        Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
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
    let action: () -> Void

    private static let shape = AnyShape(Rectangle())

    var body: some View {
        GridControlButton(
            theme: theme, shape: Self.shape,
            restFill: isSelected ? theme.tabRest : .clear,
            restForeground: isSelected ? theme.textStrong : theme.textDim,
            hoverEnabled: hoverEnabled, forced: forced, action: action
        ) {
            HStack(spacing: ChromeMetrics.TitleBar.tabGlyphGap) {
                // An explicit square rather than a font glyph: a glyph's
                // layout box carries the font's descent and sits the drawing
                // low.
                ViewTabGlyph(tab: tab)
                    .frame(width: ChromeMetrics.TitleBar.tabGlyphSize, height: ChromeMetrics.TitleBar.tabGlyphSize)
                    .foregroundStyle(isSelected ? theme.accent : theme.textLabel)
                Text(tab.title)
                    .font(ChromeType.viewTab(selected: isSelected))
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
            .padding(.horizontal, ChromeMetrics.TitleBar.tabHorizontalPadding)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(theme.accent).frame(height: ChromeMetrics.TitleBar.tabUnderline)
                }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
        }
        .background(WindowDragExclusion())
        .help("\(tab.title) (\(ShortcutLabel.text(key: ViewCommand.show(tab).key, modifiers: ViewCommand.show(tab).modifiers)))")
        .accessibilityIdentifier("flock.titleBar.tab.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
