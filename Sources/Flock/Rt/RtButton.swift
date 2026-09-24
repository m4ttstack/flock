import FlockCore
import SwiftUI

/// The pane legend's rt control. At rest, one square that opens the popover.
/// While the pane has running rt run items or a runner, one pill holding two
/// targets: the badge and the count open the popover, the divider and the
/// glyph show the runner.
struct RtButton: View {
    let theme: Theme
    let paneID: PaneID
    let appearance: RtButtonModel.Appearance
    let onOpenPopover: () -> Void
    let onShowRunner: () -> Void

    private typealias Metrics = ChromeMetrics.RtButton

    var body: some View {
        switch appearance {
        case .absent:
            EmptyView()
        case .rest:
            Button(action: onOpenPopover) {
                RtBadge()
                    .frame(width: Metrics.restSize.width, height: Metrics.restSize.height)
                    .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(theme.palette.surface0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("rt")
            .accessibilityIdentifier("flock.pane.rtButton.\(paneID.rawValue)")
        case let .active(count, runner):
            HStack(spacing: 0) {
                popoverHalf(count: count, runner: runner)
                if runner { runnerHalf }
            }
            .frame(height: Metrics.activeHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(theme.palette.selectionBg)))
        }
    }

    /// Owns the gap before the divider, so the halves meet at the divider's
    /// leading edge and a click anywhere in the pill lands on one of them.
    private func popoverHalf(count: Int, runner: Bool) -> some View {
        Button(action: onOpenPopover) {
            HStack(spacing: Metrics.gap) {
                RtBadge()
                if count > 0 {
                    Text("\(count)")
                        .font(ChromeType.rtButtonCount)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: Metrics.countHeight)
                }
            }
            .padding(.leading, Metrics.horizontalPadding)
            .padding(.trailing, runner ? Metrics.gap : Metrics.horizontalPadding)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "rt, \(count) running" : "rt")
        .accessibilityIdentifier("flock.pane.rtButton.\(paneID.rawValue)")
    }

    private var runnerHalf: some View {
        Button(action: onShowRunner) {
            HStack(spacing: Metrics.gap) {
                Rectangle()
                    .fill(theme.overlay0)
                    .frame(width: Metrics.dividerSize.width, height: Metrics.dividerSize.height)
                Image(systemName: "waveform.path.ecg")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(RtBrand.pink)
                    .frame(width: Metrics.runnerGlyphSize, height: Metrics.runnerGlyphSize)
            }
            .padding(.trailing, Metrics.horizontalPadding)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show runner")
        .accessibilityIdentifier("flock.pane.rtRunner.\(paneID.rawValue)")
    }
}
