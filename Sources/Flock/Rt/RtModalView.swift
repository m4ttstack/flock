import FlockCore
import SwiftUI

/// The rt item on screen, over the tab area: a backdrop that dims it and
/// closes the modal on a click, and centred on it a box holding the item's
/// one pane under flock's title row, with the strip below once its command
/// has ended. Draws nothing while no item is shown.
struct RtModalView: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(TerminalTextSizeStore.self) private var terminalTextSizeStore
    @Environment(\.displayScale) private var displayScale

    private typealias Metrics = ChromeMetrics.RtModal

    var body: some View {
        if let modal = viewModel.rt.modal, let item = viewModel.rt.modalItem {
            GeometryReader { proxy in
                let scale = displayScale > 0 ? displayScale : 2
                let frame = Self.boxFrame(in: proxy.size, origin: proxy.frame(in: .global).origin, scale: scale)
                ZStack(alignment: .topLeading) {
                    backdrop
                    box(modal: modal, item: item, size: frame.size, scale: scale)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }

    /// Both edges of each axis are snapped where they land in the window, as
    /// `CanvasGrid` snaps a pane box: the pane inside sits a whole number of
    /// points in from them, so ghostty composites it on whole device pixels.
    static func boxFrame(in area: CGSize, origin: CGPoint, scale: CGFloat) -> CGRect {
        let grid = CanvasGrid(canvas: area, phase: origin, displayScale: scale)
        let margin = (1 - Metrics.sizeFraction) / 2
        let left = grid.snappedX(area.width * margin)
        let right = grid.snappedX(area.width * (1 - margin))
        let top = grid.snappedY(area.height * margin)
        let bottom = grid.snappedY(area.height * (1 - margin))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private var backdrop: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? Metrics.lightBackdropOpacity : Metrics.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
    }

    private func box(modal: RtModal, item: RtItem, size: CGSize, scale: CGFloat) -> some View {
        let stripHeight = item.strip == nil ? 0 : Metrics.Strip.height
        let area = CGSize(
            width: max(0, size.width - 2 * Metrics.paneInset),
            height: max(0, size.height - Metrics.TitleRow.height - stripHeight - 2 * Metrics.paneInset)
        )
        let fontSize = terminalTextSizeStore.points
        let fit = SurfaceGrid.fit(inner: area, cell: TerminalCellMetrics.cell(fontSize: fontSize, scale: scale))
        let paneID = shownPaneID(modal: modal, item: item)
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        return VStack(spacing: 0) {
            RtModalTitleRow(
                theme: theme, title: item.modalTitle(home: NSHomeDirectory()),
                showsBackToRunner: modal.serviceTabID != nil, onBack: back, onClose: close
            )
            RtModalPane(
                theme: theme, viewModel: viewModel, paneID: paneID, grid: PTYSize(cols: fit.cols, rows: fit.rows),
                surfaceSize: fit.size, fontSizePoints: fontSize, isFocused: item.strip == nil, onFocus: {}
            )
            // A service shown in place of its board is another pane: it gets
            // a view of its own, so the board's surface parks as it leaves.
            .id(paneID)
            .frame(width: area.width, height: area.height)
            .padding(Metrics.paneInset)
            if let strip = item.strip {
                RtModalStripView(theme: theme, strip: strip)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(theme.pane)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.paneBorder, lineWidth: ChromeMetrics.ruleWidth))
        // Cast by a shape behind the box rather than by the box itself, which
        // would pull the terminal's surface through an offscreen pass.
        .background {
            shape
                .fill(theme.pane)
                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        }
        // The sidebar stays live under the modal, so a rename editor can be
        // open there, and the keys typed into it are not the strip's.
        .background(RtModalKeyMonitor(stripShown: item.strip != nil && !viewModel.renameEditorIsOnScreen, onClose: close))
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

/// The command and its folder, a close control, and in a runner's service
/// view a way back to the board.
struct RtModalTitleRow: View {
    let theme: Theme
    let title: String
    let showsBackToRunner: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    private typealias Metrics = ChromeMetrics.RtModal.TitleRow

    var body: some View {
        HStack(spacing: Metrics.gap) {
            if showsBackToRunner {
                Button(action: onBack) {
                    Text("← runner")
                        .font(ChromeType.rtModalBack)
                        .foregroundStyle(theme.accent)
                        .fixedSize()
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to runner")
                .accessibilityIdentifier("flock.rt.modal.backToRunner")
                Rectangle()
                    .fill(theme.rule)
                    .frame(width: Metrics.backDividerSize.width, height: Metrics.backDividerSize.height)
            }
            Text(title)
                .font(ChromeType.rtModalTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(ChromeType.rtModalClose)
                    .foregroundStyle(theme.textDim)
                    .frame(width: Metrics.closeGlyphSize, height: Metrics.closeGlyphSize)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("flock.rt.modal.close")
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.height)
        .background(theme.chrome)
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
