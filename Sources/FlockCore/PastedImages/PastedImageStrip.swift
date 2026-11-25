import CoreGraphics

/// A row of thumbnails that scrolls once it outgrows its viewport.
public struct PastedImageStrip: Equatable, Sendable {
    public let spans: [ClosedRange<CGFloat>]
    public let viewport: CGFloat
    public let offset: CGFloat

    public init(widths: [CGFloat], gap: CGFloat, viewport: CGFloat, offset: CGFloat) {
        var x: CGFloat = 0
        spans = widths.map { width in
            defer { x += width + gap }
            return x...(x + width)
        }
        self.viewport = viewport
        self.offset = offset
    }

    public var contentWidth: CGFloat { spans.last?.upperBound ?? 0 }
    public var overflow: CGFloat { max(0, contentWidth - viewport) }
    public var canPageBack: Bool { offset > 1 }
    public var canPageForward: Bool { offset < overflow - 1 }

    /// The thumbnails at least half in view, counted from 1.
    public var shown: ClosedRange<Int>? {
        let shown = spans.indices.filter { index in
            let span = spans[index]
            let visible = min(span.upperBound, offset + viewport) - max(span.lowerBound, offset)
            return visible >= (span.upperBound - span.lowerBound) / 2
        }
        guard let first = shown.first, let last = shown.last else { return nil }
        return (first + 1)...(last + 1)
    }

    /// Starts the next page on the first thumbnail this one cuts off.
    public var nextPage: CGFloat {
        let cut = spans.first { $0.upperBound > offset + viewport + 1 }?.lowerBound ?? overflow
        return clamped(cut > offset + 1 ? cut : offset + viewport)
    }

    /// Ends the previous page on the last thumbnail this one cuts off.
    public var previousPage: CGFloat {
        let cut = spans.last { $0.lowerBound < offset - 1 }?.upperBound ?? 0
        return clamped(cut < offset + viewport - 1 ? cut - viewport : offset - viewport)
    }

    /// Where to scroll for the thumbnail at `index` to be whole, nil if it is.
    public func revealing(_ index: Int) -> CGFloat? {
        guard overflow > 0, spans.indices.contains(index) else { return nil }
        let span = spans[index]
        if span.lowerBound < offset { return clamped(span.lowerBound) }
        if span.upperBound > offset + viewport { return clamped(span.upperBound - viewport) }
        return nil
    }

    private func clamped(_ x: CGFloat) -> CGFloat { min(max(0, x), overflow) }
}

/// Where the Quick Look panel goes: by what was clicked, in screen
/// coordinates (y up).
public enum QuickLookPlacement {
    public static let gap: CGFloat = 10
    public static let edgeMargin: CGFloat = 12
    static let minimumContent = CGSize(width: 360, height: 240)
    /// Of the window's width.
    static let widthFraction: CGFloat = 0.75

    /// Centered over `anchor` and clear above it, or under it where there is
    /// more room, kept on the screen. `chrome` is the panel's title bar.
    public static func frame(
        image: CGSize, anchor: CGRect, window: CGRect, visibleScreen: CGRect, chrome: CGFloat
    ) -> CGRect {
        let screen = visibleScreen.insetBy(dx: edgeMargin, dy: edgeMargin)
        let over = screen.maxY - anchor.maxY - gap
        let under = anchor.minY - gap - screen.minY
        let limit = CGSize(
            width: min(screen.width, max(minimumContent.width, window.width * widthFraction)),
            height: max(minimumContent.height, max(over, under) - chrome)
        )
        let scale = min(limit.width / max(1, image.width), limit.height / max(1, image.height), 1)
        let size = CGSize(
            width: min(screen.width, max(minimumContent.width, image.width * scale)),
            height: min(screen.height, max(minimumContent.height, image.height * scale) + chrome)
        )
        let y = over >= under ? anchor.maxY + gap : anchor.minY - gap - size.height
        return CGRect(
            x: min(max(anchor.midX - size.width / 2, screen.minX), screen.maxX - size.width),
            y: min(max(y, screen.minY), screen.maxY - size.height),
            width: size.width, height: size.height
        ).integral
    }

    /// For a panel that has been moved: where it is, kept on the screen.
    public static func frame(size: CGSize, centeredOn frame: CGRect, visibleScreen: CGRect) -> CGRect {
        let screen = visibleScreen.insetBy(dx: edgeMargin, dy: edgeMargin)
        let size = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        return CGRect(
            x: min(max(frame.midX - size.width / 2, screen.minX), screen.maxX - size.width),
            y: min(max(frame.midY - size.height / 2, screen.minY), screen.maxY - size.height),
            width: size.width, height: size.height
        ).integral
    }

    /// An image in the panel's content: never past its own size in the one it
    /// was `placed` in, and larger by as much as that has been enlarged.
    public static func image(_ image: CGSize, in content: CGSize, placedIn placed: CGSize) -> CGRect {
        func fit(_ size: CGSize) -> CGFloat {
            min(size.width / max(1, image.width), size.height / max(1, image.height))
        }
        let enlarged = max(1, min(content.width / max(1, placed.width), content.height / max(1, placed.height)))
        let scale = min(fit(content), min(1, fit(placed)) * enlarged)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (content.width - size.width) / 2, y: (content.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

/// What an event is to a key whose press has been acted on: the rest of that
/// press, and whether the press ends with it.
public enum HeldKey {
    public static func read(_ key: UInt16, isDown: Bool, isRepeat: Bool, of eventKey: UInt16) -> (rest: Bool, ends: Bool) {
        guard eventKey == key else { return (false, false) }
        if isDown { return isRepeat ? (true, false) : (false, true) }
        return (true, true)
    }
}

/// What a drop held over a pane says it would do.
public enum PaneDropLabel {
    public static func text(count: Int, allImages: Bool) -> String {
        let noun = allImages ? "image" : "file"
        return count <= 1 ? "Drop \(noun)" : "Drop \(count) \(noun)s"
    }
}
