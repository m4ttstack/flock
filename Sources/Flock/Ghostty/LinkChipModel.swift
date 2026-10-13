import FlockCore
import Foundation
import Observation

/// One pane's link chip, as its views read it. `LinkChipState` decides; this
/// stamps each change and wakes at the state's deadline, since a rest or a
/// grace ends without any event to say so.
@MainActor
@Observable
final class LinkChipModel {
    private(set) var chip: LinkChip?
    /// The chip as drawn, in the pane's top-left space. The surface under it
    /// reads this to leave the chip's clicks and hovers alone.
    @ObservationIgnored var frame: CGRect?
    @ObservationIgnored private var state = LinkChipState()
    @ObservationIgnored private var wake: Task<Void, Never>?

    func hover(_ link: PaneLink?, anchor: LinkChip.Anchor) {
        change { $0.hover(link, anchor: anchor, now: $1) }
    }

    func pointerLeftPane() {
        hover(nil, anchor: LinkChip.Anchor(x: 0, lineTop: 0, lineBottom: 0))
    }

    func chipHover(_ inside: Bool) {
        change { $0.chipHover(inside, now: $1) }
    }

    func dismiss() {
        change { state, _ in state.dismiss() }
    }

    private func change(_ body: (inout LinkChipState, Date) -> Void) {
        let now = Date()
        body(&state, now)
        refresh(now)
    }

    private func refresh(_ now: Date) {
        state.tick(now)
        let next = state.chip(at: now)
        if next != chip { chip = next }
        if next == nil { frame = nil }
        wake?.cancel()
        guard let deadline = state.deadline else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refresh(Date())
        }
    }
}
