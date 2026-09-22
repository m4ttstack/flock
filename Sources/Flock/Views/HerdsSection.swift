import AppKit
import FlockCore
import SwiftUI

/// The rail's last list: one row per herd, under a header that folds it.
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

    @Environment(SectionCollapseStore.self) private var collapse

    var body: some View {
        let isCollapsed = collapse.isCollapsed(.herds)
        VStack(alignment: .leading, spacing: ChromeMetrics.Rail.rowGap) {
            RailSectionHeader(
                theme: theme, title: "HERDS", isCollapsed: isCollapsed,
                accessibilityIdentifier: "flock.rail.herds.toggle", toggle: { collapse.toggle(.herds) }
            ) {
                // The section's one mark. Rows carry none: one moving glyph
                // says "something in here is still going" without a row of
                // them competing for the eye.
                HerdMark(theme: theme, size: ChromeMetrics.RailSection.headerMark, isMoving: summary.isAnyRunning)
            } trailing: {
                // The summary is the only notice a folded section gives, so
                // it is the last thing a narrow rail gets to cut.
                Text(summary.text)
                    .font(ChromeType.workspaceCount)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if !isCollapsed {
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
        .padding(.top, ChromeMetrics.RailSection.sectionGap)
    }
}

private struct HerdRow: View {
    let theme: Theme
    let herd: HerdRail.Herd
    let isSelected: Bool
    let showsFill: Bool

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            // The dot's slot, left empty, so herd names start where
            // workspace names do.
            Color.clear
                .frame(width: ChromeMetrics.WorkspaceRow.statusDot, height: 1)
            Text(herd.name)
                .font(ChromeType.workspaceName(selected: isSelected))
                .foregroundStyle(isSelected ? theme.textStrong : theme.textDim)
                .lineLimit(1)
            Spacer(minLength: ChromeMetrics.WorkspaceRow.countMinimumGap)
            // The same bare figure the workspace rows carry in this column.
            // "done" cost the name about 35pt at the default rail width,
            // and the name is the one thing this row is for.
            Text("\(herd.done)/\(herd.total)")
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
/// shared by every row in every section so the lists read as one rail.
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
