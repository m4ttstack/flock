import CoreGraphics
import Foundation

/// The chip a pane shows over a link the pointer rested on.
public struct LinkChip: Equatable {
    /// Where the hovered link sits, in the pane's top-left space: the
    /// pointer's x, and the top and bottom of the text line under it.
    public struct Anchor: Equatable {
        public let x: CGFloat
        public let lineTop: CGFloat
        public let lineBottom: CGFloat

        public init(x: CGFloat, lineTop: CGFloat, lineBottom: CGFloat) {
            self.x = x
            self.lineTop = lineTop
            self.lineBottom = lineBottom
        }
    }

    /// The chip's two buttons: Open, and the one beside it (Reveal for a
    /// file, Copy for an address).
    public enum Action: Equatable {
        case open
        case second
    }

    public let link: PaneLink
    public let anchor: Anchor

    public init(link: PaneLink, anchor: Anchor) {
        self.link = link
        self.anchor = anchor
    }

    /// The chip's top-left corner: centred on the pointer just above the
    /// link's line, kept inside the pane, and under the line instead when
    /// there is no room above it.
    public static func origin(for anchor: Anchor, chip: CGSize, pane: CGSize, gap: CGFloat, inset: CGFloat) -> CGPoint {
        let farthest = max(inset, pane.width - chip.width - inset)
        let x = min(max(anchor.x - chip.width / 2, inset), farthest)
        let above = anchor.lineTop - gap - chip.height
        return CGPoint(x: x, y: above >= inset ? above : anchor.lineBottom + gap)
    }
}

/// When the chip is up. Every change is stamped by its caller, so the rule
/// holds no timer; `deadline` says when the answer next changes by itself.
public struct LinkChipState {
    /// How long the pointer rests on a link before the chip comes up.
    public static let rest: TimeInterval = 0.3
    /// How long the chip outlives the pointer leaving its link, which is the
    /// time the pointer has to reach it.
    public static let grace: TimeInterval = 0.3
    /// How long the chip stays, its button lit, after an action was taken.
    public static let flash: TimeInterval = 0.15

    private enum Phase {
        case idle
        case resting(PaneLink, LinkChip.Anchor, since: Date)
        case shown(LinkChip, leftAt: Date?)
        /// An action was taken, and the chip is saying which.
        case acted(LinkChip, LinkChip.Action, until: Date)
        /// Sent away by the user. The same link stays quiet until the
        /// pointer has been off it.
        case dismissed(PaneLink)
    }

    private var phase = Phase.idle
    private var pointerOnChip = false

    public init() {}

    /// The pointer moved in the pane, over `link` or over none.
    public mutating func hover(_ link: PaneLink?, anchor: LinkChip.Anchor, now: Date) {
        settle(now)
        guard let link else {
            switch phase {
            case .shown(let chip, nil): phase = .shown(chip, leftAt: now)
            case .shown, .acted: break
            case .idle, .resting, .dismissed: phase = .idle
            }
            return
        }
        switch phase {
        case .resting(link, _, let since): phase = .resting(link, anchor, since: since)
        case .shown(let chip, _) where chip.link == link: phase = .shown(chip, leftAt: nil)
        case .dismissed(link), .acted: break
        default: phase = .resting(link, anchor, since: now)
        }
    }

    /// The pointer went onto the chip, or came off it.
    public mutating func chipHover(_ inside: Bool, now: Date) {
        settle(now)
        pointerOnChip = inside
        guard case .shown(let chip, _) = phase else { return }
        phase = .shown(chip, leftAt: inside ? nil : now)
    }

    /// `action` was taken on `link`, by its chip or by a click on the link
    /// itself. The chip says so where it already is; a click that came
    /// before the rest was over brings it up at `anchor` to say it.
    public mutating func act(_ action: LinkChip.Action, on link: PaneLink, anchor: LinkChip.Anchor, now: Date) {
        settle(now)
        var chip = LinkChip(link: link, anchor: anchor)
        if case .shown(let shown, _) = phase, shown.link == link { chip = shown }
        phase = .acted(chip, action, until: now.addingTimeInterval(Self.flash))
        pointerOnChip = false
    }

    /// A key, a click elsewhere, or a scroll.
    public mutating func dismiss() {
        switch phase {
        case .resting(let link, _, _): phase = .dismissed(link)
        case .shown(let chip, _), .acted(let chip, _, _): phase = .dismissed(chip.link)
        case .idle, .dismissed: break
        }
        pointerOnChip = false
    }

    /// Applies whatever time alone has changed, which moves `deadline` on.
    public mutating func tick(_ now: Date) {
        settle(now)
    }

    public func chip(at now: Date) -> LinkChip? {
        var settled = self
        settled.settle(now)
        switch settled.phase {
        case .shown(let chip, _), .acted(let chip, _, _): return chip
        case .idle, .resting, .dismissed: return nil
        }
    }

    /// The button to light, while the chip is saying an action was taken.
    public func flash(at now: Date) -> LinkChip.Action? {
        var settled = self
        settled.settle(now)
        guard case .acted(_, let action, _) = settled.phase else { return nil }
        return action
    }

    public var deadline: Date? {
        switch phase {
        case .resting(_, _, let since): return since.addingTimeInterval(Self.rest)
        case .shown(_, let leftAt?): return leftAt.addingTimeInterval(Self.grace)
        case .acted(_, _, let until): return until
        case .idle, .shown, .dismissed: return nil
        }
    }

    private mutating func settle(_ now: Date) {
        if case .resting(let link, let anchor, let since) = phase, now >= since.addingTimeInterval(Self.rest) {
            phase = .shown(LinkChip(link: link, anchor: anchor), leftAt: nil)
            pointerOnChip = false
        }
        if case .shown(_, let leftAt?) = phase, !pointerOnChip, now >= leftAt.addingTimeInterval(Self.grace) {
            phase = .idle
        }
        if case .acted(let chip, _, let until) = phase, now >= until {
            phase = .dismissed(chip.link)
        }
    }
}
