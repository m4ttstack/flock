import CoreGraphics

/// A thumbnail's mini panes with the slot a previewed drop opens among them,
/// as the rects one animation carries between two of these.
///
/// The slot never appears at its full size. It opens from a zero-thickness
/// line on the outer side of the split it makes, which is where the target
/// pane's own edge rests, so at every fraction of one shared curve the slot
/// takes exactly the span the target pane gives up and the two cannot cross.
public struct DropReflow: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        /// What a slot is the same slot as: a drop moved onto another pane or
        /// another edge closes this slot where it is and opens a new one,
        /// rather than sliding one wash across the panes in between.
        public struct Key: Hashable, Sendable {
            public let target: PaneID
            public let edge: Edge?
        }

        public let key: Key
        public let frame: CGRect
        /// Where the slot opens from and closes back to.
        public let collapsed: CGRect
    }

    /// Every mini pane but the arriving one.
    public let panes: [MiniPaneLayout.Placed]
    public let slot: Slot?

    public init(panes: [MiniPaneLayout.Placed], slot: Slot?) {
        self.panes = panes
        self.slot = slot
    }

    /// `boxes` as `MiniPaneLayout.boxes` lays them out for `arriving`, and
    /// `resting` as it lays them out with no drop, which is what says whether
    /// the arriving pane is already one of this tab's.
    public init(boxes: [MiniPaneLayout.Placed], resting: [MiniPaneLayout.Placed], arriving: MiniPaneLayout.Arrival?) {
        guard let arriving, let box = boxes.first(where: { $0.pane == arriving.pane }),
              let key = Self.key(of: arriving, fromAnotherTab: !resting.contains { $0.pane == arriving.pane })
        else {
            self.init(panes: boxes.filter { $0.pane != arriving?.pane }, slot: nil)
            return
        }
        self.init(
            panes: boxes.filter { $0.pane != arriving.pane },
            slot: Slot(key: key, frame: box.frame, collapsed: Self.collapsed(box.frame, toward: key.edge))
        )
    }

    /// The side the slot opens from is the side the drop splits the target
    /// on. A pane from another tab dropped inside a pane divides it on the
    /// right; one of this tab's trades places, which opens from no edge.
    private static func key(of arriving: MiniPaneLayout.Arrival, fromAnotherTab: Bool) -> Slot.Key? {
        switch arriving.target {
        case .paneEdge(let target, let edge):
            return Slot.Key(target: target, edge: edge)
        case .paneInterior(let target):
            return Slot.Key(target: target, edge: fromAnotherTab ? .right : nil)
        default:
            return nil
        }
    }

    /// `frame` squeezed to zero thickness against its `edge` side, or to its
    /// centre when it opens from no edge.
    public static func collapsed(_ frame: CGRect, toward edge: Edge?) -> CGRect {
        switch edge {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
        case .right: CGRect(x: frame.maxX, y: frame.minY, width: 0, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)
        case .bottom: CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 0)
        case nil: CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
        }
    }

    /// What is drawn `progress` of the way from `from` to `to` when both move
    /// under one animation: every pane in both slides between its two boxes,
    /// a slot kept under the same key slides too, and a slot that changes key
    /// closes into its own line while the new one opens out of its own. A
    /// pane only in `to` is drawn where it lands; one only in `from` is
    /// leaving and is not drawn.
    public static func drawn(from: DropReflow, to: DropReflow, progress: CGFloat) -> (panes: [MiniPaneLayout.Placed], slots: [CGRect]) {
        let before = Dictionary(from.panes.map { ($0.pane, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let panes = to.panes.map { placed in
            MiniPaneLayout.Placed(pane: placed.pane, frame: before[placed.pane].map { lerp($0, placed.frame, progress) } ?? placed.frame)
        }
        var slots: [CGRect] = []
        switch (from.slot, to.slot) {
        case let (old?, new?) where old.key == new.key:
            slots = [lerp(old.frame, new.frame, progress)]
        case let (old, new):
            if let old { slots.append(lerp(old.frame, old.collapsed, progress)) }
            if let new { slots.append(lerp(new.collapsed, new.frame, progress)) }
        }
        return (panes, slots)
    }

    /// The preview held `progress` of the way open from `resting`, for a
    /// render that cannot see a running animation.
    public static func held(from resting: DropReflow, to preview: DropReflow, progress: CGFloat) -> DropReflow {
        let drawn = drawn(from: resting, to: preview, progress: progress)
        let slot = preview.slot.map { slot in
            Slot(key: slot.key, frame: lerp(slot.collapsed, slot.frame, progress), collapsed: slot.collapsed)
        }
        return DropReflow(panes: drawn.panes, slot: slot)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t
        )
    }
}
