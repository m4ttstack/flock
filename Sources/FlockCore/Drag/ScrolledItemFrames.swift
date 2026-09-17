import CoreGraphics

/// A scrollable list's item frames, held in the list's own content space and
/// placed on screen through where that content currently sits.
///
/// Scrolling changes only the content origin, never a content-space frame,
/// so every on-screen frame follows a scroll at once with no item reporting
/// again. That holds while a reorder has frozen item reports too, so a list
/// auto-scrolling during a reorder still resolves drops against where its
/// items really are. The origin and the item frames are
/// independent reports, so the order they arrive in within a frame cannot
/// leave an item misplaced.
public struct ScrolledItemFrames<ID: Hashable & Sendable>: Equatable, Sendable {
    public struct Placed: Equatable, Sendable {
        public let id: ID
        public let frame: CGRect
    }

    public private(set) var order: [ID] = []
    public private(set) var contentOrigin: CGPoint = .zero
    private var contentFrames: [ID: CGRect] = [:]

    public init() {}

    /// Drops the frame of every item no longer listed, so a later item that
    /// reuses a slot never inherits a stale frame.
    @discardableResult
    public mutating func setOrder(_ order: [ID]) -> Bool {
        guard self.order != order else { return false }
        self.order = order
        let live = Set(order)
        contentFrames = contentFrames.filter { live.contains($0.key) }
        return true
    }

    @discardableResult
    public mutating func setContentFrame(_ frame: CGRect, for id: ID) -> Bool {
        guard contentFrames[id] != frame else { return false }
        contentFrames[id] = frame
        return true
    }

    @discardableResult
    public mutating func setContentOrigin(_ origin: CGPoint) -> Bool {
        guard contentOrigin != origin else { return false }
        contentOrigin = origin
        return true
    }

    /// In list order, skipping any item that has not reported a frame yet.
    public var onScreen: [Placed] {
        order.compactMap { id in
            contentFrames[id].map { Placed(id: id, frame: $0.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)) }
        }
    }
}
