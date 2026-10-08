import FlockCore
import SwiftUI

/// The rt item on screen, over the tab area: a `ChromeModal` holding the
/// item's one pane under flock's title row, with the strip below once its
/// command has ended. Draws nothing while no item is shown over its canvas.
struct RtModalView: View {
    let theme: Theme
    let viewModel: SessionViewModel
    /// The pane a solo canvas under the modal shows; nil over the main canvas.
    var solo: PaneID? = nil

    @Environment(RtModalTextSizeStore.self) private var textSizeStore
    @Environment(RtModalSizeStore.self) private var modalSizeStore
    @Environment(CommandPaletteState.self) private var commandPalette

    var body: some View {
        if viewModel.rtModalIsOver(solo: solo), let modal = viewModel.rt.modal, let item = viewModel.rt.modalItem {
            let paneID = shownPaneID(modal: modal, item: item)
            let fontSize = textSizeStore.points(for: item.kind)
            ChromeModal(
                theme: theme, size: modalSizeStore.size(for: item.kind),
                footerHeight: item.strip == nil ? 0 : ChromeMetrics.RtModal.Strip.height,
                onSize: { modalSizeStore.select($0, for: item.kind) }, onDismiss: close
            ) {
                RtModalTitle(
                    theme: theme, title: item.modalTitle(home: NSHomeDirectory()),
                    showsBackToRunner: modal.serviceTabID != nil, onBack: back
                )
            } content: { area, scale in
                let fit = SurfaceGrid.fit(inner: area, cell: TerminalCellMetrics.cell(fontSize: fontSize, scale: scale))
                // A service is never typed into: only the item's own pane waits
                // for its command.
                ModalTerminalPane(
                    theme: theme, viewModel: viewModel, paneID: paneID, grid: PTYSize(cols: fit.cols, rows: fit.rows),
                    surfaceSize: fit.size, fontSizePoints: fontSize, isFocused: item.strip == nil,
                    command: modal.serviceTabID != nil ? nil : ModalTerminalPane.Command(
                        started: item.started, startedAt: item.startedAt, ended: item.strip != nil || !item.isRunning
                    ),
                    onFocus: {}
                )
                // A service shown in place of its board is another pane: it gets
                // a view of its own, so the board's surface parks as it leaves.
                .id(paneID)
            } footer: {
                if let strip = item.strip { RtModalStripView(theme: theme, strip: strip) }
            }
            // The sidebar stays live under the modal, so a rename editor can be
            // open there, and the keys typed into it are not the strip's; nor
            // are the palette's, which can open over the modal.
            .background(RtModalKeyMonitor(
                stripShown: item.strip != nil && !viewModel.renameEditorIsOnScreen && !commandPalette.isOpen, onClose: close
            ))
        }
    }

    /// Every hidden rt tab holds one pane. Until the model has the tab the
    /// modal has just switched to, the item's own pane stands in.
    private func shownPaneID(modal: RtModal, item: RtItem) -> PaneID {
        viewModel.fullModel?.panes.values.first { $0.tabID == modal.shownTabID }?.paneID ?? item.firstPaneID
    }

    private func close() {
        Task { await viewModel.rt.closeModal() }
    }

    private func back() {
        Task { await viewModel.rt.backToBoard() }
    }
}

/// The back button to the runner's board in a runner's service view, its
/// divider, and the command and its folder.
struct RtModalTitle: View {
    let theme: Theme
    let title: String
    let showsBackToRunner: Bool
    let onBack: () -> Void

    private typealias Metrics = ChromeMetrics.Modal.TitleRow

    var body: some View {
        HStack(spacing: Metrics.gap) {
            if showsBackToRunner {
                Button(action: onBack) {
                    Text("← runner")
                        .font(ChromeType.rtModalBack)
                        .foregroundStyle(theme.accent)
                        .fixedSize()
                        .padding(.horizontal, ChromeMetrics.RtModal.backHoverPadding)
                        .frame(height: Metrics.buttonBoxSide)
                        .hoverWash(theme, cornerRadius: Metrics.buttonCornerRadius)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to runner")
                .accessibilityIdentifier("flock.rt.modal.backToRunner")
                Rectangle()
                    .fill(theme.rule)
                    .frame(
                        width: ChromeMetrics.RtModal.backDividerSize.width,
                        height: ChromeMetrics.RtModal.backDividerSize.height
                    )
            }
            Text(title)
                .font(ChromeType.modalTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// How the command ended; while it is up, any plain key closes the modal.
struct RtModalStripView: View {
    let theme: Theme
    let strip: RtStrip

    private typealias Metrics = ChromeMetrics.RtModal.Strip

    var body: some View {
        Text(strip.text)
            .font(ChromeType.rtModalStrip)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalPadding)
            .frame(height: Metrics.height)
            .background(theme.chrome)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
            }
            .accessibilityIdentifier("flock.rt.modal.strip")
    }

    private var color: Color {
        switch strip {
        case .exited: theme.red
        case .finished: theme.textStrong
        }
    }
}
