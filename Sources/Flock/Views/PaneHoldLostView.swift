import FlockCore
import SwiftUI

/// Covers a pane that has no herdr client: another client took it over, or
/// every retake was refused. The surface underneath shows a frame that is no
/// longer live, so this is opaque. Return in the pane does what the button
/// does (`GhosttySurfaceView.keyDown`).
struct PaneHoldLostView: View {
    let theme: Theme
    let reason: HoldLossReason
    let onTakeBack: () -> Void

    struct Copy: Equatable {
        let headline: String
        let body: String
        let action: String
    }

    static func copy(for reason: HoldLossReason) -> Copy {
        switch reason {
        case .takenOver:
            Copy(headline: "Open in another client", body: "Another client took over this pane.", action: "Take it back")
        case .refused:
            Copy(headline: "Couldn't reattach this pane", body: "herdr refused flock's connection.", action: "Reconnect")
        }
    }

    private typealias M = ChromeMetrics.HoldLost

    var body: some View {
        let copy = Self.copy(for: reason)
        VStack(spacing: M.spacing) {
            MonitorSmartphoneGlyph()
                .stroke(theme.textLabel, style: StrokeStyle(lineWidth: M.iconSize / 12, lineCap: .round, lineJoin: .round))
                .frame(width: M.iconSize, height: M.iconSize)
            VStack(spacing: M.textSpacing) {
                Text(copy.headline)
                    .font(ChromeType.holdLostHeadline)
                    .foregroundStyle(theme.textStrong)
                Text(copy.body)
                    .font(ChromeType.holdLostBody)
                    .foregroundStyle(theme.textLabel)
                    .multilineTextAlignment(.center)
                    .lineSpacing(M.bodyLineSpacing)
                    .frame(maxWidth: M.bodyWidth)
            }
            .padding(.top, M.textTopPadding)
            .padding(.bottom, M.textBottomPadding)
            Button(action: onTakeBack) {
                HStack(spacing: M.actionGap) {
                    Text(copy.action)
                        .font(ChromeType.holdLostAction)
                    Text("\u{21A9}")
                        .font(ChromeType.holdLostKeycap)
                        .padding(.horizontal, M.keycapHorizontalPadding)
                        .padding(.vertical, M.keycapVerticalPadding)
                        .background(RoundedRectangle(cornerRadius: M.keycapCornerRadius).fill(Color.black.opacity(0.15)))
                }
            }
            .buttonStyle(HoldLostActionStyle(theme: theme))
            .accessibilityIdentifier("flock.pane.holdLost.takeBack")
        }
        .padding(.horizontal, M.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.pane)
        .contentShape(Rectangle())
        .accessibilityIdentifier("flock.pane.holdLost")
    }
}

/// The accent whatever the window's state, as `NoHerdrPrimaryActionStyle`:
/// `.borderedProminent` greys out in a window that is not key.
private struct HoldLostActionStyle: ButtonStyle {
    let theme: Theme

    private typealias M = ChromeMetrics.HoldLost

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.pane)
            .padding(.leading, M.actionLeadingPadding)
            .padding(.trailing, M.actionTrailingPadding)
            .padding(.vertical, M.actionVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: M.actionCornerRadius)
                    .fill(theme.accent)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .contentShape(Rectangle())
    }
}

/// Lucide's `monitor-smartphone`, on its 24-point grid.
private struct MonitorSmartphoneGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 18, y: 8))
        path.addLine(to: CGPoint(x: 18, y: 6))
        path.addArc(tangent1End: CGPoint(x: 18, y: 4), tangent2End: CGPoint(x: 16, y: 4), radius: 2)
        path.addLine(to: CGPoint(x: 4, y: 4))
        path.addArc(tangent1End: CGPoint(x: 2, y: 4), tangent2End: CGPoint(x: 2, y: 6), radius: 2)
        path.addLine(to: CGPoint(x: 2, y: 13))
        path.addArc(tangent1End: CGPoint(x: 2, y: 15), tangent2End: CGPoint(x: 4, y: 15), radius: 2)
        path.addLine(to: CGPoint(x: 12, y: 15))
        path.move(to: CGPoint(x: 10, y: 15))
        path.addLine(to: CGPoint(x: 10, y: 19))
        path.move(to: CGPoint(x: 7, y: 19))
        path.addLine(to: CGPoint(x: 12, y: 19))
        path.addRoundedRect(in: CGRect(x: 16, y: 12, width: 6, height: 10), cornerSize: CGSize(width: 2, height: 2))
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
