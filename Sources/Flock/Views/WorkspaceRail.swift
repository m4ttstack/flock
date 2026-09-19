import AppKit
import FlockCore
import SwiftUI

/// The workspace sidebar: a heading over one row per workspace, with a rule on
/// its trailing edge. Read-only mirror, selection/jump, and the workspace end
/// of the drag layer.
struct WorkspaceRail: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let onSelect: (WorkspaceID) -> Void

    @Environment(DragCoordinator.self) private var drag
    @Environment(RailWidthStore.self) private var railWidth
    @State private var scrollPosition = ScrollPosition()

    private var workspaces: [WorkspaceRecord] { viewModel.model?.workspaces ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("WORKSPACES")
                    .font(ChromeType.railHeading)
                    .tracking(ChromeType.railHeadingTracking)
                    .foregroundStyle(theme.textLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Centered on the heading text and overlaid, so the
                    // button's box can never move the heading or the rows
                    // under it however large it grows.
                    .overlay(alignment: .trailing) { AllWorkspacesButton(theme: theme) }
                    .padding(.top, ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                // Only the rows scroll. The gap below the heading is scroll
                // content, so rows scroll up to the heading's edge, and the
                // horizontal padding is too, so the viewport keeps the rail's
                // full width for the insertion bar.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
                        ForEach(Array(workspaces.enumerated()), id: \.element.workspaceID) { index, workspace in
                            let isRenaming = viewModel.renameTarget == .workspace(workspace.workspaceID)
                            WorkspaceRow(
                                theme: theme,
                                workspace: workspace,
                                paneCount: viewModel.paneCount(for: workspace.workspaceID),
                                isSelected: workspace.workspaceID == viewModel.selectedWorkspaceID,
                                isRenaming: isRenaming,
                                renameText: viewModel.renameText(for: .workspace(workspace.workspaceID)),
                                onCommitRename: { text in
                                    Task { await viewModel.commitRename(text, for: .workspace(workspace.workspaceID)) }
                                },
                                onCancelRename: { viewModel.cancelRename() },
                                showsFill: drag.showsWorkspaceFill(
                                    workspace.workspaceID, isCurrent: workspace.workspaceID == viewModel.selectedWorkspaceID
                                ),
                                displacement: drag.workspaceDisplacement(at: index),
                                isGhosted: drag.isDragging(workspace: workspace.workspaceID)
                            )
                            // Outside the row, which offsets its own content: the
                            // frame published here is the row's resting place,
                            // which is what the insertion index is measured
                            // against.
                            .reportsFrame(in: DragSpace.railContent) { drag.setWorkspaceFrame($0, for: workspace.workspaceID) }
                            // A container, so the identifier below names the
                            // whole row and the controls inside it keep their
                            // own. Without it SwiftUI folds the row into its
                            // name text: the row reads as a label a third of
                            // its width, and its rename editor is not
                            // reachable at all.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("flock.rail.workspace.\(workspace.workspaceID.rawValue)")
                            // ONE tap gesture, which is what keeps a plain
                            // click instant: a `count: 2` sibling for the
                            // rename would make this one wait out the
                            // system's double-click interval before it
                            // could fire at all (`ChromeRowClick`).
                            .onTapGesture { handleClick(on: workspace.workspaceID) }
                            // Disarmed while this row is being renamed: a press
                            // inside the field must reach the text, not start a
                            // drag.
                            .simultaneousGesture(rowDrag(workspace), including: isRenaming ? .subviews : .all)
                            .contextMenu {
                                ForEach(workspaceMenuEntries(for: workspace.workspaceID), id: \.accessibilityIdentifier) { entry in
                                    Button(entry.label) {
                                        Task { await entry.action.perform(workspaceID: workspace.workspaceID, on: viewModel) }
                                    }
                                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                                }
                            }
                        }
                        // Real content, filling whatever height the rows
                        // leave inside the viewport: a `ScrollView` bridges to
                        // an `NSScrollView`, whose clip view claims hit
                        // testing across its own bounds, so a right-click
                        // past where a shorter document actually ends never
                        // reaches a layer drawn behind the scroll view at
                        // all. herdr draws a "+" of its own in the sidebar;
                        // flock's equivalent is this zone plus File > New
                        // Workspace, so the resting chrome carries no control
                        // the design never drew.
                        newWorkspaceZone
                    }
                    .padding(.top, ChromeMetrics.Rail.headingToFirstRow)
                    .padding(.bottom, ChromeMetrics.Rail.verticalPadding)
                    .padding(.horizontal, ChromeMetrics.Rail.horizontalPadding)
                    .frame(width: railWidth.width, alignment: .leading)
                    // Gives the row stack a concrete height to allocate
                    // rather than the unbounded one a `ScrollView` proposes to
                    // its content: only that turns `newWorkspaceZone`'s own
                    // `maxHeight: .infinity` into a real fill of the leftover
                    // space rather than the near-zero share SwiftUI gives a
                    // flexible child under an unbounded proposal.
                    .frame(minHeight: drag.railViewport?.height, alignment: .top)
                    .coordinateSpace(.named(DragSpace.railContent))
                    .reportsDragFrame { drag.setRailContentOrigin($0.origin) }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollPosition($scrollPosition)
                .reportsScrollExtent(.vertical) { drag.setRailScroll(offset: $0, maximumOffset: $1) }
                .frame(maxHeight: .infinity)
                .reportsDragFrame { drag.railViewport = $0 }
                .onAppear { drag.railScroller = { y in scrollPosition.scrollTo(y: y) } }
            }
            .frame(width: railWidth.width)
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth)
        }
        // Inside the rail's own bounds rather than straddling the rule: an
        // overlay drawn past its parent's edge is not reliably hit-tested
        // there, and a band that reached into the canvas would sit over the
        // pane chrome the canvas draws at its own edge.
        .overlay(alignment: .trailing) { resizeHandle }
        .boundedBackground(theme.chrome)
        .reportsDragFrame { drag.railFrame = $0 }
        .onAppear { drag.setWorkspaceOrder(workspaces.map(\.workspaceID)) }
        .onChange(of: workspaces.map(\.workspaceID)) { _, ids in drag.setWorkspaceOrder(ids) }
    }

    /// Selection on the first click, the rename editor on the second. A row
    /// the user double-clicks is therefore selected on the way into the
    /// editor, which is the price of never holding a plain click back to find
    /// out whether a second one is coming.
    private func handleClick(on workspace: WorkspaceID) {
        switch NSEvent.chromeRowClick(NSApp.currentEvent) {
        case .select:
            let commandHeld = NSEvent.modifierFlags.contains(.command)
            if drag.clickWorkspace(workspace, commandHeld: commandHeld, current: viewModel.selectedWorkspaceID) {
                onSelect(workspace)
            }
        case .beginRename:
            viewModel.beginRename(.workspace(workspace))
        case .ignore:
            break
        }
    }

    /// The rail's trailing edge, grabbable. It draws nothing: the rule is
    /// already the edge, and the resize cursor is how macOS says an edge
    /// moves. Withheld during a pane drag, which owns the closed hand for its
    /// whole duration, exactly as the canvas's dividers are.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: ChromeMetrics.Rail.resizeGrabWidth)
            .contentShape(Rectangle())
            .pointerStyle(drag.isPaneDragInFlight ? nil : .columnResize)
            .gesture(resizeGesture)
            .accessibilityLabel("Sidebar width")
            .accessibilityIdentifier("flock.rail.resize")
    }

    /// Read in the drag space, whose origin is the window's own leading edge,
    /// so the pointer's x IS the width being asked for and nothing has to be
    /// reconstructed from the rail rect this very gesture moves.
    ///
    /// The release carries its own point: motion is coalesced and can be
    /// outrun, so the last position `onChanged` reported is not where the
    /// hand finished. `RailWidthStore` is what clamps and remembers it.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(DragSpace.name))
            .onChanged { railWidth.dragged(to: $0.location.x) }
            .onEnded { railWidth.released(at: $0.location.x) }
    }

    /// A plain click on rail space no row occupies creates a workspace, and a
    /// right-click there offers the same thing by name. Invisible by
    /// construction, so it costs the resting chrome nothing. A row of its own
    /// height sits above this zone in the row stack rather than overlapping
    /// it, so a right-click that lands on a row never reaches here.
    private var newWorkspaceZone: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !NSEvent.isSecondaryButtonEvent(NSApp.currentEvent) else { return }
                Task { await viewModel.createWorkspace() }
            }
            .accessibilityIdentifier("flock.rail.newWorkspace")
            .contextMenu {
                ForEach(RailMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                    Button(entry.label) {
                        Task { await entry.action.perform(on: viewModel) }
                    }
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                }
            }
    }

    private func workspaceMenuEntries(for workspace: WorkspaceID) -> [ChromeMenuEntry<WorkspaceMenuAction>] {
        guard let model = viewModel.model else { return [] }
        return WorkspaceMenuModel.entries(for: workspace, model: model)
    }

    /// Starts the drag and nothing else: `DragCoordinator` drives it from
    /// there, off window-level monitors, so no per-row latch can be left
    /// behind by a rail that is rebuilt mid-drag.
    private func rowDrag(_ workspace: WorkspaceRecord) -> some Gesture {
        DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
            .onChanged { value in
                let subject = drag.workspaceDragSubject(pressing: workspace.workspaceID)
                let title = if case .workspaces(let block) = subject { "\(block.count) workspaces" } else { workspace.label }
                drag.beginIfIdle(
                    subject,
                    ghost: DragCoordinator.Ghost(
                        title: title,
                        symbol: "square.grid.2x2",
                        originSize: drag.workspaceFrames.first { $0.id == workspace.workspaceID }?.frame.size ?? .zero
                    ),
                    at: value.startLocation
                )
            }
    }
}

/// The way into the All Workspaces grid that does not need the menu. The way
/// back is Esc: the grid covers this rail while it is shown.
private struct AllWorkspacesButton: View {
    let theme: Theme

    @Environment(DragCoordinator.self) private var drag
    @State private var isHovering = false

    var body: some View {
        Button {
            drag.toggleGrid()
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(ChromeType.railHeadingSymbol)
        }
        .buttonStyle(HeadingButtonStyle(theme: theme, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .help("All workspaces")
        .accessibilityIdentifier("flock.rail.allWorkspaces")
    }
}

/// The selected-tab block behind the glyph, appearing on hover and taking a
/// wash of accent while the press is held.
private struct HeadingButtonStyle: ButtonStyle {
    let theme: Theme
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = isHovering || configuration.isPressed
        return configuration.label
            .foregroundStyle(lit ? theme.textStrong : theme.textLabel)
            .frame(width: ChromeMetrics.Rail.headingButtonSize, height: ChromeMetrics.Rail.headingButtonSize)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.Rail.headingButtonCornerRadius)
                    .fill(theme.selection)
                    .overlay(
                        RoundedRectangle(cornerRadius: ChromeMetrics.Rail.headingButtonCornerRadius)
                            .fill(theme.accent)
                            .opacity(configuration.isPressed ? ChromeMetrics.Rail.headingButtonPressedAccent : 0)
                    )
                    .opacity(lit ? 1 : 0)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: lit)
    }
}

private struct WorkspaceRow: View {
    let theme: Theme
    let workspace: WorkspaceRecord
    let paneCount: Int
    let isSelected: Bool
    var isRenaming = false
    var renameText = ""
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    /// The selection fill alone. The accent bar and weight always mark
    /// herdr's selected workspace; the fill follows the Cmd+click selection
    /// whenever one exists.
    var showsFill = false
    /// How far this row slides to open the insertion gap.
    var displacement: CGFloat = 0
    /// The row this drag started from, left in place and faded.
    var isGhosted = false

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            // The dot always means status, on the selected row too: selection
            // is already carried by the row fill and the heavier name, and a
            // row that swapped its status for an accent was the one row whose
            // agent you could not see.
            StatusDot(status: workspace.agentStatus, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
            if isRenaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.workspaceName(selected: isSelected), initialText: renameText,
                    accessibilityIdentifier: "flock.rail.rename.\(workspace.workspaceID.rawValue)",
                    onCommit: onCommitRename, onCancel: onCancelRename
                )
            } else {
                Text(workspace.label)
                    .font(ChromeType.workspaceName(selected: isSelected))
                    .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                    .lineLimit(1)
                Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
                Text("\(paneCount)")
                    .font(ChromeType.workspaceCount)
                    .foregroundStyle(theme.textLabel)
            }
        }
        // Fixed rather than taken from the label's line height, which varies
        // with face and size, so rows keep a whole-point pitch.
        .frame(height: ChromeMetrics.WorkspaceRow.contentHeight)
        .padding(.vertical, ChromeMetrics.WorkspaceRow.verticalPadding)
        .padding(.horizontal, ChromeMetrics.WorkspaceRow.horizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.cornerRadius)
                .fill(theme.selection)
                .opacity(showsFill ? 1 : 0)
        )
        .contentShape(Rectangle())
        .opacity(isGhosted ? DragVisuals.originOpacity : 1)
        .offset(y: displacement)
        .animation(.easeOut(duration: DragVisuals.reshuffleDuration), value: displacement)
        .animation(.easeOut(duration: 0.12), value: isGhosted)
    }
}
