import FlockCore
import SwiftUI

/// The title bar's Workspaces | Overview | Arrange tabs.
struct ViewTabBar: View {
    let theme: Theme
    /// Per tab, for renders.
    var forced: [ViewTab: ControlInteraction] = [:]

    @Environment(DragCoordinator.self) private var drag
    @Environment(AllWorkspacesModeStore.self) private var mode

    private var navigator: ViewTabNavigator { ViewTabNavigator(drag: drag, mode: mode) }

    var body: some View {
        let selected = navigator.selected
        let inert = navigator.dragInFlight
        HStack(spacing: ChromeMetrics.TitleBar.tabGap) {
            ForEach(ViewTab.allCases, id: \.self) { tab in
                ViewTabButton(
                    theme: theme, tab: tab, isSelected: tab == selected, hoverEnabled: !inert, forced: forced[tab]
                ) { navigator.choose(tab) }
            }
        }
        .allowsHitTesting(!inert)
    }
}

struct ViewTabButton: View {
    let theme: Theme
    let tab: ViewTab
    let isSelected: Bool
    var hoverEnabled = true
    var forced: ControlInteraction?
    let action: () -> Void

    private static let shape = AnyShape(UnevenRoundedRectangle(
        topLeadingRadius: ChromeMetrics.TitleBar.tabCornerRadius, topTrailingRadius: ChromeMetrics.TitleBar.tabCornerRadius
    ))

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
                Image(systemName: tab.symbolName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: ChromeMetrics.TitleBar.tabGlyphSize, height: ChromeMetrics.TitleBar.tabGlyphSize)
                    .foregroundStyle(isSelected ? theme.accent : theme.textLabel)
                Text(tab.title)
                    .font(ChromeType.viewTab(selected: isSelected))
            }
            .padding(.horizontal, ChromeMetrics.TitleBar.tabHorizontalPadding)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(theme.accent).frame(height: ChromeMetrics.TitleBar.tabUnderline)
                }
            }
        }
        .background(WindowDragExclusion())
        .help("\(tab.title) (\(ShortcutLabel.text(key: ViewCommand.show(tab).key, modifiers: ViewCommand.show(tab).modifiers)))")
        .accessibilityIdentifier("flock.titleBar.tab.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
