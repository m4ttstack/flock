import CoreText
import FlockCore
import SwiftUI

/// What the Arrange tiles in a subtree read and how large they set their
/// type. A nil interval reads nothing: the grid hands it out only to tiles
/// that are on its canvas.
struct ArrangeTileContext: Equatable {
    var interval: Duration?
    var isZoomed = false
}

private struct ArrangeTileContextKey: EnvironmentKey {
    static let defaultValue = ArrangeTileContext()
}

extension EnvironmentValues {
    var arrangeTiles: ArrangeTileContext {
        get { self[ArrangeTileContextKey.self] }
        set { self[ArrangeTileContextKey.self] = newValue }
    }
}

/// A mini pane large enough to read: the pane's own last lines, with the
/// meta line and the status timeline when the box has room for them. A view
/// of the pane, never a terminal: it takes no input and attaches nothing,
/// reading the screen through the same `pane.read` the preview card uses.
struct ArrangeTileBody: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let pane: PaneRecord
    let title: String?
    let shown: ShownStatus
    let detail: TileDetail

    @Environment(\.arrangeTiles) private var tiles
    @State private var isOnScreen = false

    private typealias G = ChromeMetrics.Grid

    private struct ReadKey: Equatable {
        let pane: PaneID
        let interval: Duration?
        let isOnScreen: Bool
    }

    var body: some View {
        let tail = viewModel.paneTails[pane.paneID]
        VStack(alignment: .leading, spacing: G.tileRowSpacing) {
            if detail >= .meta { meta }
            if let tail, !tail.isEmpty {
                GeometryReader { proxy in
                    ArrangeTailLines(
                        tail: tail, size: proxy.size,
                        maxSize: tiles.isZoomed ? G.zoomedTileTailMaxSize : G.tileTailMaxSize,
                        themeID: theme.id, palette: PaneTailPalette(theme: theme)
                    )
                    .equatable()
                }
            } else {
                placeholder
                Spacer(minLength: 0)
            }
            if detail >= .timeline {
                StatusTimeline(theme: theme, segments: viewModel.statusHistory.segments(of: pane.paneID, at: viewModel.currentTime))
                    .frame(height: G.tileTimelineHeight)
            }
        }
        .padding(.leading, G.tileLeadingPadding)
        .padding(.trailing, G.tileTrailingPadding)
        .padding(.vertical, G.tileVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
        .task(id: ReadKey(pane: pane.paneID, interval: tiles.interval, isOnScreen: isOnScreen)) {
            await read(every: tiles.interval)
        }
    }

    /// One read in flight per pane is the view model's rule; this only paces
    /// them. A tile with nothing cached reads at once, so it never sits on its
    /// placeholder for a whole cycle; after that each pane keeps its own
    /// place in the cycle.
    private func read(every interval: Duration?) async {
        guard isOnScreen, let interval else { return }
        if viewModel.paneTails[pane.paneID] == nil {
            viewModel.refreshPaneTail(for: pane.paneID)
        }
        try? await Task.sleep(for: TileTailCadence.offset(for: pane.paneID, interval: interval))
        while !Task.isCancelled {
            viewModel.refreshPaneTail(for: pane.paneID)
            try? await Task.sleep(for: interval)
        }
    }

    private var meta: some View {
        let place = viewModel.repoBranches.repoBranch(for: pane.foregroundCwd ?? pane.cwd).text
        let age = viewModel.statusHistory.age(of: pane.paneID, at: viewModel.currentTime).map(MissionAge.text)
        return HStack(spacing: G.tileMetaSpacing) {
            Text(pane.agent ?? title ?? "shell")
                .foregroundStyle(theme.shownStatusColor(shown))
                .layoutPriority(1)
            Text(age.map { "\(place) · \($0)" } ?? place)
                .foregroundStyle(theme.textLabel)
                .truncationMode(.middle)
        }
        .font(tiles.isZoomed ? ChromeType.arrangeTileMetaZoomed : ChromeType.arrangeTileMeta)
        .lineLimit(1)
    }

    /// Until the first read lands: the status word and title a small mini
    /// pane draws, so a tile never opens blank.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: G.miniPaneTitleSpacing) {
            HStack(spacing: G.miniPaneTitleSpacing) {
                StatusDot(shown: shown, theme: theme, size: G.miniPaneStatusDot)
                Text(shown.backgroundWork ?? shown.status.rawValue)
                    .font(ChromeType.gridMiniPaneStatus)
                    .foregroundStyle(shown.isBackground ? theme.backgroundWorkColor : shown.status == .blocked ? theme.red : theme.textLabel)
            }
            if detail < .meta, let title {
                Text(title).font(ChromeType.gridMiniPaneTitle).foregroundStyle(theme.textStrong)
            }
        }
        .lineLimit(1)
    }
}

/// A tail's last rows at the size its widest row fits the box at, one screen
/// row to one line and never wrapped, as the preview card draws it. Equatable
/// on what it draws, so a read of another pane redraws no tile but its own.
private struct ArrangeTailLines: View, Equatable {
    let tail: PaneTail
    let size: CGSize
    let maxSize: CGFloat
    let themeID: String
    let palette: PaneTailPalette

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tail == rhs.tail && lhs.size == rhs.size && lhs.maxSize == rhs.maxSize && lhs.themeID == rhs.themeID
    }

    var body: some View {
        let fontSize = Self.fontSize(columns: tail.rows.map(\.columns).max() ?? 0, width: size.width, maxSize: maxSize)
        let lineHeight = Self.lineHeight(fontSize)
        let fitting = lineHeight > 0 ? Int(size.height / lineHeight) : 0
        let shown = TileTailCadence.shown(count: tail.rows.count, fitting: fitting)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.self) { index in
                Text(PaneTailRendering.attributed(tail.rows[index], size: fontSize, palette: palette))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: size.width, height: lineHeight, alignment: .leading)
                    .clipped()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func fontSize(columns: Int, width: CGFloat, maxSize: CGFloat) -> CGFloat {
        let advance = PaneTailRendering.advancePerPoint
        guard columns > 0, width > 0, advance > 0 else { return maxSize }
        let fitted = ((width / (CGFloat(columns) * advance)) * 10).rounded(.down) / 10
        return min(maxSize, max(ChromeMetrics.Grid.tileTailMinSize, fitted))
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(TerminalFont.face as CFString, size, nil)
        return (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
    }
}
