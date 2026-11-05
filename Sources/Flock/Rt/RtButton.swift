import FlockCore
import SwiftUI

/// The pane bar's rt control. One button that opens the popover and, while
/// the pane has a runner, a second beside it that shows the runner. The
/// divider between them drops while either is hovered, so the key reads as
/// one piece.
struct RtButton: View {
    let theme: Theme
    let paneID: PaneID
    let appearance: RtButtonModel.Appearance
    let onOpenPopover: () -> Void
    let onShowRunner: () -> Void

    @State private var hoveredHalf: Half?

    private enum Half { case popover, runner }

    private typealias M = ChromeMetrics.PaneBar

    private var hasRunner: Bool {
        if case .active(_, runner: true) = appearance { return true }
        return false
    }

    var body: some View {
        if appearance != .absent {
            HStack(spacing: 0) {
                popoverHalf
                if hasRunner {
                    Rectangle()
                        .fill(LauncherStripStyle(theme: theme).divider)
                        .frame(width: M.rtDividerSize.width, height: M.rtDividerSize.height)
                        .opacity(hoveredHalf == nil ? 1 : 0)
                    runnerHalf
                }
            }
        }
    }

    private var popoverHalf: some View {
        Button(action: onOpenPopover) {
            Text("rt").font(ChromeType.paneBarRt)
        }
        .buttonStyle(PaneBarKeyStyle(style: LauncherStripStyle(theme: theme), width: hasRunner ? M.rtHalfWidth : M.keySize.width))
        .onHover { hoveredHalf = $0 ? .popover : nil }
        .accessibilityLabel("rt")
        .accessibilityIdentifier("flock.pane.rtButton.\(paneID.rawValue)")
    }

    private var runnerHalf: some View {
        Button(action: onShowRunner) {
            Image(systemName: "waveform.path.ecg")
                .resizable()
                .scaledToFit()
                .foregroundStyle(RtBrand.pink)
                .frame(width: M.glyphSize, height: M.glyphSize)
        }
        .buttonStyle(PaneBarKeyStyle(style: LauncherStripStyle(theme: theme), width: M.rtHalfWidth))
        .onHover { hoveredHalf = $0 ? .runner : nil }
        .accessibilityLabel("Show runner")
        .accessibilityIdentifier("flock.pane.rtRunner.\(paneID.rawValue)")
    }
}
