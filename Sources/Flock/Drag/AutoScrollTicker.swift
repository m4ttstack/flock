import AppKit
import QuartzCore

/// Calls back once per display refresh with the seconds since the previous
/// call, for as long as it runs. Added in the common run loop modes because a
/// held mouse button keeps the run loop in event tracking, where a default
/// mode link would never fire.
///
/// The link retains its target, so `stop()` is what breaks that cycle; an
/// owner must call it on every path that ends a drag.
@MainActor
final class AutoScrollTicker: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var onTick: ((Double) -> Void)?

    var isRunning: Bool { link != nil }

    func start(on view: NSView, _ tick: @escaping (Double) -> Void) {
        guard link == nil else { return }
        onTick = tick
        lastTimestamp = nil
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        onTick = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTimestamp.map { now - $0 } ?? 0
        lastTimestamp = now
        onTick?(elapsed)
    }
}
