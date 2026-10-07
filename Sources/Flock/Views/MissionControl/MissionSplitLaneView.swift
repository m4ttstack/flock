import FlockCore
import SwiftUI

/// One of the two subgroups a split lane draws.
enum MissionSubgroup: String, CaseIterable {
    case blocked, done, working, background

    var title: String { rawValue.uppercased() }

    /// The space the subgroup's scroll content is measured in, so a card's
    /// place in it ignores how far the subgroup is scrolled.
    var space: NamedCoordinateSpace { .named("flock.mission.subgroup.\(rawValue)") }
}

/// What the split lanes measure, and where each subgroup was scrolled to.
/// Overview leaves the view hierarchy while a card is open in the focused
/// view, so this outlives it: coming back keeps each subgroup's offset and
/// draws the split it had, rather than an even one for a frame. One per
/// session view model, so two windows never share a split.
@MainActor
@Observable
final class MissionLaneMemory {
    @ObservationIgnored private static let byOwner = NSMapTable<AnyObject, MissionLaneMemory>.weakToStrongObjects()

    static func of(_ owner: AnyObject) -> MissionLaneMemory {
        if let memory = byOwner.object(forKey: owner) { return memory }
        let memory = MissionLaneMemory()
        byOwner.setObject(memory, forKey: owner)
        return memory
    }

    /// The subgroup's scroll content at its own height, unconstrained.
    var contentHeight: [MissionSubgroup: CGFloat] = [:]
    /// The bottom of the subgroup's first card, in its content's space.
    var firstCardBottom: [MissionSubgroup: CGFloat] = [:]
    var labelHeight: [MissionSubgroup: CGFloat] = [:]
    /// The height below a lane's heading, keyed by the lane's top subgroup.
    var laneHeight: [MissionSubgroup: CGFloat] = [:]
    @ObservationIgnored var offsets: [MissionSubgroup: CGFloat] = [:]

    /// A split changes in a pass of its own, never animated: frame heights
    /// that animate would hand the measurement an in-between split.
    func record(
        _ value: CGFloat, in keyPath: ReferenceWritableKeyPath<MissionLaneMemory, [MissionSubgroup: CGFloat]>,
        for subgroup: MissionSubgroup
    ) {
        guard self[keyPath: keyPath][subgroup] != value else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { self[keyPath: keyPath][subgroup] = value }
    }
}

/// A subgroup as its lane holds it.
struct MissionSubgroupSlot: Equatable {
    let kind: MissionSubgroup
    /// Its cards in drawn order.
    let cards: [PaneID]

    var isEmpty: Bool { cards.isEmpty }
}

/// Below a lane's heading: its top subgroup, then its bottom one, each a
/// label over its own scroll area, sharing the height as `LaneSplit` says.
/// An empty subgroup draws nothing; with both empty, `emptyMessage` is drawn.
struct SplitLaneBody<Content: View>: View {
    let theme: Theme
    let memory: MissionLaneMemory
    let top: MissionSubgroupSlot
    let bottom: MissionSubgroupSlot
    let emptyMessage: String?
    let selection: PaneID?
    @ViewBuilder let content: (MissionSubgroup) -> Content

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        let allocation = allocation()
        Group {
            if top.isEmpty && bottom.isEmpty {
                if let emptyMessage {
                    Text(emptyMessage).font(ChromeType.missionEmpty).foregroundStyle(theme.textLabel)
                        .padding(M.selectionInset)
                }
            } else {
                VStack(alignment: .leading, spacing: M.subgroupGap) {
                    if !top.isEmpty { slot(top, height: allocation?.top) }
                    if !bottom.isEmpty { slot(bottom, height: allocation?.bottom) }
                }
                .padding(.top, M.subgroupTopPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            memory.record($0, in: \.laneHeight, for: top.kind)
        }
    }

    private func slot(_ slot: MissionSubgroupSlot, height: CGFloat?) -> some View {
        let label = memory.labelHeight[slot.kind] ?? 0
        let scrollHeight = height.map { max(0, $0 - label - M.subgroupLabelGap) }
        return VStack(alignment: .leading, spacing: M.subgroupLabelGap) {
            LaneSubgroupLabel(theme: theme, title: slot.kind.title, count: slot.cards.count)
                .padding(.horizontal, M.selectionInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    memory.record($0, in: \.labelHeight, for: slot.kind)
                }
                .accessibilityIdentifier("flock.mission.subgroup.\(slot.kind.rawValue)")
            SubgroupScroll(memory: memory, kind: slot.kind, cards: slot.cards, selection: selection) { content(slot.kind) }
                .frame(height: scrollHeight)
        }
    }

    /// Nil until the lane and every non-empty subgroup have been measured.
    private func allocation() -> LaneSplit.Allocation? {
        guard let lane = memory.laneHeight[top.kind] else { return nil }
        func heights(_ slot: MissionSubgroupSlot) -> (natural: CGFloat, floor: CGFloat)? {
            guard !slot.isEmpty else { return (0, 0) }
            guard let label = memory.labelHeight[slot.kind], let content = memory.contentHeight[slot.kind] else { return nil }
            let chrome = label + M.subgroupLabelGap
            let firstCard = memory.firstCardBottom[slot.kind].map { $0 + M.groupPadding + M.selectionInset } ?? content
            return (chrome + content, chrome + min(content, firstCard))
        }
        guard let t = heights(top), let b = heights(bottom) else { return nil }
        let gap = top.isEmpty || bottom.isEmpty ? 0 : M.subgroupGap
        return LaneSplit.allocate(
            top: t.natural, bottom: b.natural, height: lane - M.subgroupTopPadding - gap, topFloor: t.floor, bottomFloor: b.floor
        )
    }
}

/// One subgroup's scroll area. Its content is measured inside the scroll
/// view, where its height does not depend on the frame the split gives it.
private struct SubgroupScroll<Content: View>: View {
    let memory: MissionLaneMemory
    let kind: MissionSubgroup
    let cards: [PaneID]
    let selection: PaneID?
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition()

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: M.cardGap) { content() }
                    .padding(M.selectionInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .coordinateSpace(kind.space)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        memory.record($0, in: \.contentHeight, for: kind)
                    }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                memory.offsets[kind] = offset
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            // Clipped top and bottom only: a card moving to another lane is
            // drawn by the subgroup it lands in, and has to stay visible as
            // it crosses from its old lane.
            .scrollClipDisabled()
            .mask { Rectangle().padding(.horizontal, -M.crossLaneReach) }
            .onAppear {
                if let offset = memory.offsets[kind] { position.scrollTo(y: offset) }
                guard let selection, cards.contains(selection) else { return }
                // After the restored offset has been applied, so the card is
                // brought into view from where the subgroup was left.
                Task { @MainActor in reader.scrollTo(selection) }
            }
            .onChange(of: selection) { _, selected in
                if let selected, cards.contains(selected) { withAnimation { reader.scrollTo(selected) } }
            }
        }
    }
}

extension View {
    /// Reports a subgroup's first card's bottom, which with its label is the
    /// least of the subgroup a split may show.
    func missionSubgroupFloor(_ subgroup: MissionSubgroup?, in memory: MissionLaneMemory) -> some View {
        onGeometryChange(for: CGFloat?.self) { proxy in
            subgroup.map { proxy.frame(in: $0.space).maxY }
        } action: { bottom in
            if let subgroup, let bottom { memory.record(bottom, in: \.firstCardBottom, for: subgroup) }
        }
    }
}

/// A split lane's subgroup label, in At rest's section-label style: the
/// title and count, then a hairline to the lane's edge.
struct LaneSubgroupLabel: View {
    let theme: Theme
    let title: String
    let count: Int

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        HStack(spacing: M.restLabelSpacing) {
            HStack(spacing: M.subgroupCountSpacing) {
                Text(title).tracking(M.restLabelTracking)
                Text("\(count)")
            }
            .font(ChromeType.missionRestSection)
            .foregroundStyle(theme.textLabel.opacity(M.restLabelOpacity))
            .lineLimit(1)
            .fixedSize()
            Rectangle().fill(theme.rule).frame(height: ChromeMetrics.ruleWidth)
        }
    }
}

/// A lane heading's mark: which of the lane's statuses it holds. One status
/// is its own dot; two put the bottom subgroup's dot behind and the top's in
/// front to its right, cut out of the back one by a ring of the lane's
/// ground. An empty lane keeps `resting`, so the heading never loses its dot.
struct LaneMark: View {
    let theme: Theme
    /// The top subgroup's status while it holds cards.
    let front: ShownStatus?
    /// The bottom subgroup's status while it holds cards.
    let back: ShownStatus?
    let resting: ShownStatus
    let ground: Color
    let size: CGFloat

    private typealias M = ChromeMetrics.MissionControl

    var body: some View {
        if let front, let back {
            let offset = size * M.laneMarkOffset
            let cutout = size * M.laneMarkCutout
            ZStack(alignment: .leading) {
                StatusDot(shown: back, theme: theme, size: size)
                Circle()
                    .fill(ground)
                    .frame(width: size + 2 * cutout, height: size + 2 * cutout)
                    .offset(x: offset - cutout)
                StatusDot(shown: front, theme: theme, size: size)
                    .offset(x: offset)
            }
            .frame(width: size + offset, height: size, alignment: .leading)
        } else {
            StatusDot(shown: front ?? back ?? resting, theme: theme, size: size)
        }
    }
}
