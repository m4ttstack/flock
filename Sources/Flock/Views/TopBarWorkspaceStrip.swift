import FlockCore
import SwiftUI

/// The title bar's top-bar workspaces: one button per pin, in pin order,
/// drawn like menu-bar extras.
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
            HStack(spacing: ChromeMetrics.TitleBar.topBarButtonGap) {
                ForEach(rows, id: \.pin.id) { row in
                    TopBarCellLabel(theme: theme, viewModel: viewModel, row: row, showsName: showsNames)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: ChromeMetrics.TitleBar.topBarButtonGap) {
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
        }
    }

    private func isOpen(_ row: RailSections.PinnedRow) -> Bool {
        viewModel.topBarOverlay.openPin == row.pin.id
    }
}

/// A button's content: the pin's symbol, then its name when names show.
/// Status is the symbol's colour; an empty pin's symbol and name are dimmed.
private struct TopBarCellLabel: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let row: RailSections.PinnedRow
    let showsName: Bool

    var body: some View {
        let pin = row.pin
        let isEmpty = row.record == nil
        let ink = isEmpty ? theme.textStrong.opacity(ChromeMetrics.TitleBar.topBarEmptyOpacity) : theme.textStrong
        HStack(spacing: ChromeMetrics.TitleBar.topBarNameGap) {
            WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.TitleBar.topBarIcon, foreground: iconColor(ink))
            if showsName {
                Text(pin.name)
                    .font(ChromeType.viewTab(selected: false))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, ChromeMetrics.TitleBar.topBarButtonPadding)
        .frame(height: ChromeMetrics.TitleBar.topBarButtonHeight)
    }

    /// The rail dot's colour while an agent is active or background work
    /// runs; otherwise the label's own ink.
    private func iconColor(_ ink: Color) -> Color {
        guard let status = viewModel.topBarStatus(of: row.pin) else { return ink }
        if status.isBackground { return theme.shownStatusColor(status) }
        return theme.agentStatusColor(status.status) ?? ink
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

    /// No ground at rest; the chrome's hover wash under the pointer, and
    /// only the stronger open wash while open, so hover never outshines it.
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.TitleBar.topBarButtonRadius)
        let ground: Color = isOpen ? theme.menuBarOpenWash
            : isHovering ? theme.text.opacity(ChromeMetrics.HoverWash.opacity) : .clear
        return TopBarCellLabel(theme: theme, viewModel: viewModel, row: row, showsName: showsName)
            .background(shape.fill(ground).allowsHitTesting(false))
            .contentShape(shape)
            .fadingHover($isHovering)
    }

    private func toggle() {
        Task { await viewModel.toggleTopBar(pin.id) }
    }
}
