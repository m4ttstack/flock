import FlockCore
import SwiftUI

/// The title bar's top-bar workspaces: one cell per pin, in pin order,
/// drawn like the view tabs.
struct TopBarWorkspaceStrip: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let showsNames: Bool
    /// The title bar's hidden copy, laid out only for its width: it reports
    /// no drag frames and carries no menu, hit target or accessibility node.
    var measuring = false

    @Environment(DragCoordinator.self) private var drag
    @Environment(TopBarOverlaySizeStore.self) private var sizes

    var body: some View {
        let rows = viewModel.railSections(board: nil)?.topBar ?? []
        if measuring {
            HStack(spacing: 0) {
                ForEach(rows, id: \.pin.id) { row in
                    TopBarCellLabel(theme: theme, viewModel: viewModel, row: row, showsName: showsNames, isOpen: isOpen(row))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.pin.id) { index, row in
                    TopBarCell(
                        theme: theme, viewModel: viewModel, row: row, showsName: showsNames, isOpen: isOpen(row),
                        onUnpin: { sizes.forget(row.pin.id) }
                    )
                    .offset(x: drag.topBarDisplacement(at: index))
                    .reportsDragFrame { drag.setTopBarFrame($0, for: row.pin.id) }
                }
            }
            .reportsDragFrame { drag.setTopBarRegion($0) }
            .onChange(of: rows.map(\.pin.id), initial: true) { _, order in drag.setTopBarOrder(order) }
            .onDisappear { drag.setTopBarOrder([]) }
            .overlay(alignment: .leading) {
                if !rows.isEmpty {
                    Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
                }
            }
        }
    }

    private func isOpen(_ row: RailSections.PinnedRow) -> Bool {
        viewModel.topBarOverlay.openPin == row.pin.id
    }
}

/// A cell's content: the pin's symbol with its status dot, then its name when
/// names show. An empty pin's symbol and name are dimmed and carry no dot.
private struct TopBarCellLabel: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let row: RailSections.PinnedRow
    let showsName: Bool
    let isOpen: Bool

    var body: some View {
        let pin = row.pin
        let dimmed = row.record == nil ? theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity) : nil
        HStack(spacing: ChromeMetrics.TitleBar.tabGlyphGap) {
            WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.TitleBar.topBarMark, foreground: dimmed)
                .overlay(alignment: .topTrailing) {
                    if let status = viewModel.topBarStatus(of: pin) {
                        let dot = ChromeMetrics.TitleBar.topBarDot
                        StatusDot(shown: status, theme: theme, size: dot)
                            .offset(x: dot / 2, y: -dot / 2)
                    }
                }
            if showsName {
                Text(pin.name)
                    .font(ChromeType.viewTab(selected: isOpen))
                    .foregroundStyle(dimmed.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, ChromeMetrics.TitleBar.topBarCellPadding)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if isOpen {
                Rectangle().fill(theme.accent).frame(height: ChromeMetrics.TitleBar.tabUnderline)
            }
        }
    }
}

private struct TopBarCell: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let row: RailSections.PinnedRow
    let showsName: Bool
    let isOpen: Bool
    let onUnpin: () -> Void

    @Environment(DragCoordinator.self) private var drag
    @Environment(WorkspaceIdentityStore.self) private var identityStore
    @State private var picking = false
    @State private var renaming = false
    @State private var isHovering = false

    private var pin: PinnedWorkspace { row.pin }

    var body: some View {
        face
        // A tap gesture rather than a Button: a Button also fires when a drag
        // is released back over the cell it started on, toggling the overlay.
        .onTapGesture { toggle() }
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
        }
        .background(WindowDragExclusion())
        .opacity(drag.isDragging(pin: pin.id) ? DragVisuals.originOpacity : 1)
        .simultaneousGesture(
            DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
                .onChanged { value in
                    drag.beginIfIdle(
                        drag.pinDragSubject(pin.id),
                        ghost: DragCoordinator.Ghost(
                            title: pin.name, symbol: identityStore.symbol(for: pin.identityKey) ?? "square.grid.2x2",
                            originSize: drag.topBarFrames.first { $0.id == pin.id }?.frame.size ?? .zero
                        ),
                        at: value.startLocation
                    )
                },
            isEnabled: !renaming && !picking
        )
        .workspaceSymbolPopover(theme: theme, key: pin.identityKey, isPresented: $picking)
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            InlineRenameField(
                theme: theme, font: ChromeType.workspaceName(selected: false), initialText: pin.name,
                accessibilityIdentifier: "flock.topBar.rename.\(pin.id.rawValue)",
                onCommit: { text in
                    renaming = false
                    Task { await viewModel.renameTopBarPin(pin.id, to: text) }
                },
                onCancel: { renaming = false }
            )
            .frame(width: ChromeMetrics.TitleBar.renameWidth)
            .padding()
        }
        .contextMenu {
            ForEach(TopBarMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                Button(entry.label) {
                    switch entry.action {
                    case .moveToSidebar: viewModel.moveToSidebar(pin: pin.id, at: nil)
                    case .rename: renaming = true
                    case .changeSymbol: picking = true
                    case .unpin:
                        viewModel.unpinTopBar(pin.id)
                        onUnpin()
                    }
                }
                .accessibilityIdentifier(entry.accessibilityIdentifier)
            }
        }
        .help(pin.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.name)
        .accessibilityIdentifier("flock.titleBar.topBar.\(pin.id.rawValue)")
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
    }

    /// `GridControlButton`'s rest and hover, without its press.
    private var face: some View {
        let appearance = GridControlAppearance.resolve(
            theme: theme, restForeground: isOpen ? theme.textStrong : theme.textDim, isHovering: isHovering, isPressed: false
        )
        return TopBarCellLabel(theme: theme, viewModel: viewModel, row: row, showsName: showsName, isOpen: isOpen)
            .foregroundStyle(appearance.foreground)
            .background(
                GridControlGround(
                    theme: theme, shape: AnyShape(Rectangle()), restFill: isOpen ? theme.tabRest : .clear, appearance: appearance
                )
            )
            .contentShape(Rectangle())
            .fadingHover($isHovering)
    }

    private func toggle() {
        Task { await viewModel.toggleTopBar(pin.id) }
    }
}
