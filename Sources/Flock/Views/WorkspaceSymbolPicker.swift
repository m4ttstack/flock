import FlockCore
import SwiftUI

/// What a workspace's "Symbol…" item opens: Automatic, then every group's
/// symbols as a scrolling grid of icons, Automatic pinned above it. Picking one reports it and leaves the popover
/// to the caller to close.
struct WorkspaceSymbolPicker: View {
    let theme: Theme
    /// The symbol the workspace wears now, whether picked or assigned.
    let current: String?
    let isAutomatic: Bool
    let onPick: (String?) -> Void

    private typealias Metrics = ChromeMetrics.SymbolPicker

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Metrics.cellSize), spacing: Metrics.cellGap), count: Metrics.columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            automatic
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    ForEach(WorkspaceSymbols.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: Metrics.labelGap) {
                            Text(group.title.uppercased())
                                .font(ChromeType.paletteSection)
                                .tracking(Metrics.labelTracking)
                                .foregroundStyle(theme.textLabel)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.cellGap) {
                                ForEach(group.symbols, id: \.name) { cell($0) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.maxGridHeight)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(theme.palette.panelBg)))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(Color(theme.palette.surface1), lineWidth: ChromeMetrics.ruleWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .background(PopoverAppearancePin(isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)))
    }

    private var automatic: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cellCornerRadius)
        return GridControlButton(
            theme: theme, shape: AnyShape(shape), restFill: selectedGround(isAutomatic),
            restForeground: theme.textStrong, action: { onPick(nil) }
        ) {
            Text("Automatic")
                .font(ChromeType.paletteName)
                .padding(.horizontal, Metrics.automaticHorizontalPadding)
                .frame(height: Metrics.automaticHeight)
        }
        .overlay(selectedOutline(isAutomatic, rest: theme.rule))
        .accessibilityIdentifier("flock.identity.symbol.automatic")
    }

    private func cell(_ symbol: WorkspaceSymbols.Symbol) -> some View {
        let isSelected = symbol.name == current
        let shape = RoundedRectangle(cornerRadius: Metrics.cellCornerRadius)
        return GridControlButton(
            theme: theme, shape: AnyShape(shape), restFill: selectedGround(isSelected),
            restForeground: theme.textStrong, action: { onPick(symbol.name) }
        ) {
            Image(systemName: symbol.name)
                .font(.system(size: Metrics.glyphSize))
                .frame(width: Metrics.cellSize, height: Metrics.cellSize)
        }
        .overlay(selectedOutline(isSelected))
        .help(symbol.title)
        .accessibilityLabel(symbol.title)
        .accessibilityIdentifier("flock.identity.symbol.\(symbol.name)")
    }

    private func selectedGround(_ isSelected: Bool) -> Color {
        isSelected ? theme.accent.opacity(Metrics.selectedFill) : .clear
    }

    private func selectedOutline(_ isSelected: Bool, rest: Color = .clear) -> some View {
        RoundedRectangle(cornerRadius: Metrics.cellCornerRadius)
            .strokeBorder(isSelected ? theme.accent.opacity(Metrics.selectedStroke) : rest, lineWidth: ChromeMetrics.ruleWidth)
            .allowsHitTesting(false)
    }
}

/// Attaches a workspace's symbol picker as a popover on the view it modifies.
/// Picking closes it.
private struct WorkspaceSymbolPopover: ViewModifier {
    let theme: Theme
    let key: String?
    @Binding var isPresented: Bool

    @Environment(WorkspaceIdentityStore.self) private var identityStore

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let key {
                WorkspaceSymbolPicker(
                    theme: theme, current: identityStore.symbol(for: key),
                    isAutomatic: identityStore.overrides[key] == nil
                ) { name in
                    identityStore.setOverride(name, for: key)
                    isPresented = false
                }
            }
        }
    }
}

extension View {
    func workspaceSymbolPopover(theme: Theme, key: String?, isPresented: Binding<Bool>) -> some View {
        modifier(WorkspaceSymbolPopover(theme: theme, key: key, isPresented: isPresented))
    }
}
