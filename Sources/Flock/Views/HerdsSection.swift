import AppKit
import FlockCore
import SwiftUI

/// The rail's second list: one row per herd, under a header that folds it.
/// Herd rows carry no status dot, because every gate a worker raises is the
/// shepherd's to answer; they say how far the herd has got and whether
/// anything in it is still moving. `HerdRail` decides all of that.
struct HerdsSection: View {
    let theme: Theme
    let herds: [HerdRail.Herd]
    let summary: HerdRail.Summary
    let selectedWorkspaceID: WorkspaceID?
    let showsFill: (WorkspaceID) -> Bool
    let onClick: (WorkspaceID) -> Void

    @Environment(HerdsSectionStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
            header
            if !store.isCollapsed {
                ForEach(herds, id: \.workspaceID) { herd in
                    HerdRow(
                        theme: theme, herd: herd,
                        isSelected: herd.workspaceID == selectedWorkspaceID,
                        showsFill: showsFill(herd.workspaceID)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("flock.rail.herd.\(herd.workspaceID.rawValue)")
                    .onTapGesture { onClick(herd.workspaceID) }
                }
            }
        }
        .padding(.top, ChromeMetrics.Herds.sectionGap)
    }

    private var header: some View {
        Button(action: store.toggle) {
            HStack(spacing: ChromeMetrics.Herds.headerChevronGap) {
                Image(systemName: store.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(ChromeType.herdsChevron)
                    .frame(width: ChromeMetrics.Herds.headerChevron)
                Text("HERDS")
                    .font(ChromeType.railHeading)
                    .tracking(ChromeType.railHeadingTracking)
                    .fixedSize()
                Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
                // The summary is the only notice a folded section gives, so
                // it is the last thing a narrow rail gets to cut.
                HStack(spacing: ChromeMetrics.Herds.headerSummaryGap) {
                    HerdMark(theme: theme, size: ChromeMetrics.Herds.headerMark, isMoving: summary.isAnyRunning)
                    Text(summary.text)
                        .font(ChromeType.workspaceCount)
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }
            .padding(.leading, -(ChromeMetrics.Herds.headerChevron + ChromeMetrics.Herds.headerChevronGap))
            .foregroundStyle(theme.textLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, ChromeMetrics.Rail.headingGap)
        .accessibilityIdentifier("flock.rail.herds.toggle")
        .accessibilityValue(store.isCollapsed ? "collapsed" : "expanded")
    }
}

private struct HerdRow: View {
    let theme: Theme
    let herd: HerdRail.Herd
    let isSelected: Bool
    let showsFill: Bool

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            HerdMark(theme: theme, size: ChromeMetrics.Herds.rowMark, isMoving: herd.isRunning)
                .frame(width: ChromeMetrics.WorkspaceRow.statusDot)
            Text(herd.name)
                .font(ChromeType.workspaceName(selected: isSelected))
                .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                .lineLimit(1)
            Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
            Text("\(herd.done)/\(herd.total) done")
                .font(ChromeType.workspaceCount)
                .foregroundStyle(theme.textLabel)
                .lineLimit(1)
        }
        .opacity(herd.isFinished ? ChromeMetrics.Herds.finishedOpacity : 1)
        .modifier(RailRowChrome(theme: theme, showsFill: showsFill))
    }
}

/// The ram as a grey glyph, drifting while its herd works and still when it
/// does not. Only the echoes move, as in the loader, so the leader stays put
/// where the eye already found it.
struct HerdMark: View {
    let theme: Theme
    let size: CGFloat
    let isMoving: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if isMoving && !reduceMotion {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start) * ChromeMetrics.Herds.motionTempo
                HerdrRamMark(size: size, progress: { delay in
                    PaneLoaderChoreography.mergeProgress(elapsed: elapsed, startDelay: delay) * ChromeMetrics.Herds.motionDepth
                }, tint: theme.textLabel, echoOpacityScale: ChromeMetrics.Herds.markEchoOpacity)
            }
        } else {
            HerdrRamMark(size: size, tint: theme.textLabel, echoOpacityScale: ChromeMetrics.Herds.markEchoOpacity)
        }
    }
}

/// A rail row's box: the fixed pitch, the padding and the selection fill,
/// shared by workspace and herd rows so the two lists read as one rail.
struct RailRowChrome: ViewModifier {
    let theme: Theme
    let showsFill: Bool

    func body(content: Content) -> some View {
        content
            // Fixed rather than taken from the label's line height, which
            // varies with face and size, so rows keep a whole-point pitch.
            .frame(height: ChromeMetrics.WorkspaceRow.contentHeight)
            .padding(.vertical, ChromeMetrics.WorkspaceRow.verticalPadding)
            .padding(.horizontal, ChromeMetrics.WorkspaceRow.horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.cornerRadius)
                    .fill(theme.selection)
                    .opacity(showsFill ? 1 : 0)
            )
            .contentShape(Rectangle())
    }
}
