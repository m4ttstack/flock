import CoreGraphics

public enum Edge: CaseIterable, Sendable {
    case top, bottom, left, right
}

public struct DividerHandle: Equatable, Sendable {
    public let tabID: TabID
    public let path: [Bool]
    public let frame: CGRect
    public let direction: SplitDirection
}

public struct CanvasGeometry: Equatable, Sendable {
    public let paneFrames: [PaneID: CGRect]
    public let dividers: [DividerHandle]

    public init(layout: LayoutSnapshot, in size: CGSize, dividerThickness: CGFloat = 6) {
        let area = layout.area
        guard area.width > 0, area.height > 0 else {
            paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, .zero) })
            dividers = []
            return
        }

        let scaleX = size.width / CGFloat(area.width)
        let scaleY = size.height / CGFloat(area.height)
        func scale(_ rect: CellRect) -> CGRect {
            CGRect(
                x: CGFloat(rect.x - area.x) * scaleX,
                y: CGFloat(rect.y - area.y) * scaleY,
                width: CGFloat(rect.width) * scaleX,
                height: CGFloat(rect.height) * scaleY
            )
        }

        paneFrames = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneID, scale($0.rect)) })
        dividers = CanvasGeometry.dividerHandles(
            splits: layout.splits,
            area: area,
            tabID: layout.tabID,
            scale: scale,
            thickness: dividerThickness
        )
    }

    /// Splits nest by rect containment, not array order: the root is the split
    /// spanning the full layout area; a split contained in a parent's first-child
    /// region gets `false` appended to the parent's path, the second-child region
    /// gets `true`. A split whose parent cannot be resolved this way is dropped
    /// rather than guessed at.
    private static func dividerHandles(
        splits: [SplitInfo],
        area: CellRect,
        tabID: TabID,
        scale: (CellRect) -> CGRect,
        thickness: CGFloat
    ) -> [DividerHandle] {
        guard let root = splits.first(where: { $0.rect == area }) ?? splits.max(by: { cellArea($0.rect) < cellArea($1.rect) }) else {
            return []
        }

        var paths: [String: [Bool]] = [root.id: []]
        var remaining = splits.filter { $0.id != root.id }
        var madeProgress = true
        while madeProgress && !remaining.isEmpty {
            madeProgress = false
            for split in remaining {
                guard let parent = splits.first(where: { candidate in
                    paths[candidate.id] != nil
                        && (contains(candidate.firstChildRegion, split.rect) || contains(candidate.secondChildRegion, split.rect))
                }), let parentPath = paths[parent.id] else { continue }
                let branch = contains(parent.secondChildRegion, split.rect)
                paths[split.id] = parentPath + [branch]
                remaining.removeAll { $0.id == split.id }
                madeProgress = true
            }
        }

        return splits.compactMap { split in
            guard let path = paths[split.id] else { return nil }
            let full = scale(split.rect)
            return DividerHandle(
                tabID: tabID,
                path: path,
                frame: dividerFrame(for: split, fullFrame: full, thickness: thickness),
                direction: split.direction
            )
        }
    }

    private static func dividerFrame(for split: SplitInfo, fullFrame: CGRect, thickness: CGFloat) -> CGRect {
        switch split.direction {
        case .right:
            let boundaryX = fullFrame.minX + CGFloat(split.ratio) * fullFrame.width
            return CGRect(x: boundaryX - thickness / 2, y: fullFrame.minY, width: thickness, height: fullFrame.height)
        case .down:
            let boundaryY = fullFrame.minY + CGFloat(split.ratio) * fullFrame.height
            return CGRect(x: fullFrame.minX, y: boundaryY - thickness / 2, width: fullFrame.width, height: thickness)
        }
    }

    private static func cellArea(_ rect: CellRect) -> Int { rect.width * rect.height }

    private static func contains(_ region: CellRect, _ rect: CellRect) -> Bool {
        rect.x >= region.x && rect.y >= region.y
            && rect.x + rect.width <= region.x + region.width
            && rect.y + rect.height <= region.y + region.height
    }
}

private extension SplitInfo {
    var firstChildRegion: CellRect {
        switch direction {
        case .right:
            let firstWidth = Int((Double(rect.width) * ratio).rounded())
            return CellRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height)
        case .down:
            let firstHeight = Int((Double(rect.height) * ratio).rounded())
            return CellRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight)
        }
    }

    var secondChildRegion: CellRect {
        let first = firstChildRegion
        switch direction {
        case .right:
            return CellRect(x: rect.x + first.width, y: rect.y, width: rect.width - first.width, height: rect.height)
        case .down:
            return CellRect(x: rect.x, y: rect.y + first.height, width: rect.width, height: rect.height - first.height)
        }
    }
}
