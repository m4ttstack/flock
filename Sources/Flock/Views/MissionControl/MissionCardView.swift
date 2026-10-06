import FlockCore
import SwiftUI

/// Window-space frames of the cards on screen, read by render tests.
@MainActor
final class MissionCardFrames {
    static let shared = MissionCardFrames()
    var frames: [PaneID: CGRect] = [:]
}

struct MissionCardView: View {
    let theme: Theme
    let card: MissionCard
    /// Repo and branch as Settings > Overview > Bottom line words them; nil
    /// leaves the timeline alone on its line.
    let place: String?
    let segments: [PaneStatusHistory.Segment]
    let now: Date
    let isSelected: Bool
    let isCooling: Bool
    var forced: ControlInteraction?
    /// Set while this card's pane is being renamed: the title becomes the
    /// rename field, and the card stops being a button so clicks reach it.
    var rename: PaneRename?
    let activate: () -> Void

    @State private var isHovering = false

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        surface
            .overlay(
                RoundedRectangle(cornerRadius: M.cardCornerRadius)
                    .strokeBorder(outline, lineWidth: outlineWidth)
                    .allowsHitTesting(false)
            )
            .opacity(isCooling ? M.coolingOpacity : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                MissionCardFrames.shared.frames[card.paneID] = $0
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: M.cardCornerRadius + M.selectionInset)
                        .strokeBorder(theme.accent, lineWidth: M.selectionOutline)
                        .padding(-M.selectionInset)
                        .allowsHitTesting(false)
                }
            }
            .fadingHover($isHovering)
            .pointerStyle(.link)
            .accessibilityIdentifier("flock.mission.card.\(card.paneID.rawValue)")
    }

    private var shape: AnyShape { AnyShape(RoundedRectangle(cornerRadius: M.cardCornerRadius)) }

    private var restFill: Color { theme.chrome }

    @ViewBuilder
    private var surface: some View {
        if rename != nil {
            content.background(
                GridControlGround(
                    theme: theme, shape: shape, restFill: restFill,
                    appearance: .resolve(theme: theme, restForeground: theme.textStrong, isHovering: false, isPressed: false)
                )
            )
        } else {
            Button(action: activate) { content }
                .buttonStyle(GridControlStyle(
                    theme: theme, shape: shape, restFill: restFill,
                    restForeground: theme.textStrong, pressAccent: M.cardPressedAccent,
                    isHovering: forced?.isHovering ?? isHovering, forcePressed: forced?.isPressed ?? false
                ))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: M.cardLineSpacing) {
            HStack(spacing: 8) {
                StatusDot(status: card.status, theme: theme, size: M.cardDot)
                title
                Spacer(minLength: 8)
                stateText
            }
            if let detail = card.detail {
                Text(detail)
                    .font(ChromeType.missionCardDetail)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                if let place {
                    Text(place)
                        .font(ChromeType.missionCardMono)
                        .foregroundStyle(theme.textLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
                Spacer(minLength: 8)
                StatusTimeline(theme: theme, segments: segments)
                    .frame(minWidth: M.timelineMinimumWidth, maxWidth: M.timelineWidth)
                    .frame(height: M.timelineHeight)
            }
        }
        .padding(.vertical, M.cardVerticalPadding)
        .padding(.horizontal, M.cardHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateText: some View {
        Text(card.stateText(at: now))
            .font(ChromeType.missionCardMono)
            .foregroundStyle(theme.agentStatusMarkColor(card.status))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var title: some View {
        if let rename {
            InlineRenameField(
                theme: theme, font: ChromeType.missionCardTitle, initialText: rename.initialText,
                accessibilityIdentifier: "flock.mission.rename.\(card.paneID.rawValue)",
                onCommit: rename.commit, onCancel: rename.cancel
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(card.title)
                .font(ChromeType.missionCardTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outline: Color {
        card.status == .blocked ? theme.red : theme.rule
    }

    private var outlineWidth: CGFloat {
        card.status == .blocked ? M.blockedOutline : ChromeMetrics.ruleWidth
    }
}

/// The last hour of one pane, oldest at the left: working, blocked and done
/// as solid bands, idle as a thin line, unrecorded time as the track alone.
struct StatusTimeline: View {
    let theme: Theme
    let segments: [PaneStatusHistory.Segment]

    var body: some View {
        GeometryReader { proxy in
            let drawn = PaneStatusHistory.Segment.drawable(segments, width: proxy.size.width)
            let total = drawn.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            HStack(spacing: 0) {
                ForEach(Array(drawn.enumerated()), id: \.offset) { _, segment in
                    let width = total > 0 ? proxy.size.width * segment.end.timeIntervalSince(segment.start) / total : 0
                    band(segment.status)
                        .frame(width: width, height: proxy.size.height)
                }
            }
        }
        .background(theme.tabRest)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func band(_ status: AgentStatus?) -> some View {
        switch status {
        case .some(let status) where status == .working || status == .blocked || status == .done:
            Rectangle().fill(theme.agentStatusMarkColor(status))
        case .some(.idle):
            Rectangle().fill(theme.green.opacity(0.55))
                .frame(height: ChromeMetrics.MissionControl.timelineIdleHeight)
        default:
            Color.clear
        }
    }
}

/// A pane rename in progress, as a card shows it.
struct PaneRename {
    let initialText: String
    let commit: (String) -> Void
    let cancel: () -> Void
}
