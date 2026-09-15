import Foundation

/// One herdr `terminal.frame` line, decoded: the ANSI bytes, the grid herdr
/// rendered them for (its own `width`/`height`), and whether they redraw every
/// cell rather than diff against the previous frame.
public struct HerdrFrame: Equatable, Sendable {
    public let bytes: Data
    public let size: PTYSize?
    public let full: Bool

    public init(bytes: Data, size: PTYSize?, full: Bool) {
        self.bytes = bytes
        self.size = size
        self.full = full
    }
}

/// Which herdr frames a bridge writes to its PTY, and when it asks herdr for a
/// full repaint.
///
/// libghostty parses a frame into whatever grid its terminal holds at that
/// moment, and applies a new surface size to that terminal only after its own
/// resize coalescing, well after paddock has declared the size to herdr. So a
/// frame is written only when herdr rendered it for the declared grid AND the
/// PTY winsize agrees (libghostty sets the winsize in the same step as its
/// terminal resize). Every other frame is dropped. A drop leaves herdr's diff
/// baseline holding a frame the surface never received, so it owes one forced
/// same-dims resize (herdr answers any resize with a full frame), sent once
/// the surface is at the declared grid. A settle request owes the same repaint
/// through the same latch, so the two never stack.
///
/// Pure: every input carries the PTY winsize as `surface` (nil when it cannot
/// be read, which leaves frames ungated by it), and every output is `Effects`
/// for the caller to carry out.
public struct BridgeFrameGate: Equatable, Sendable {
    public enum Repaint: Equatable, Sendable {
        case none
        /// Needed; sent as soon as the surface is at `declared`.
        case owed
        /// Sent; the next full frame written at `declared` clears it.
        case requested
    }

    public struct Effects: Equatable, Sendable {
        /// A `terminal.resize` to send at this size.
        public var resize: PTYSize?
        /// Call `surfaceWaitExpired(token:surface:)` with this token after
        /// `surfaceWaitMilliseconds`.
        public var surfaceWait: Int?

        public init(resize: PTYSize? = nil, surfaceWait: Int? = nil) {
            self.resize = resize
            self.surfaceWait = surfaceWait
        }
    }

    private enum SurfaceWait: Equatable, Sendable {
        case none
        case waiting(Int)
        case expired
    }

    /// How long the surface may disagree with the declared grid before frames
    /// flow regardless. Well past libghostty's 25ms resize coalescing plus a
    /// layout pass, so it only ever expires when the surface's grid never
    /// lands on the declared one, where holding frames would freeze the pane.
    public static let surfaceWaitMilliseconds = 200

    public private(set) var declared: PTYSize?
    public private(set) var repaint: Repaint = .none
    private var baselineBroken = false
    private var wait: SurfaceWait = .none
    private var waitTokens = 0

    public init(declared: PTYSize? = nil) {
        self.declared = declared
    }

    /// Paddock declared `size` for the pane, with `wantsRepaint` set when a
    /// resize gesture has just ended.
    public mutating func declare(_ size: PTYSize, repaint wantsRepaint: Bool, surface: PTYSize?) -> Effects {
        var effects = Effects()
        var send = false
        if size != declared {
            declared = size
            wait = .none
            send = true
            if repaint != .none { repaint = .owed }
        }
        if wantsRepaint, repaint == .none { repaint = .owed }
        let ready = surfaceReady(surface, &effects)
        if repaint == .owed, ready {
            // The size change's own resize already makes herdr repaint in full.
            repaint = .requested
            send = true
        }
        if send { effects.resize = size }
        return effects
    }

    /// The PTY winsize changed.
    public mutating func surfaceResized(surface: PTYSize?) -> Effects {
        var effects = Effects()
        fireIfOwed(ready: surfaceReady(surface, &effects), effects: &effects)
        return effects
    }

    public mutating func surfaceWaitExpired(token: Int, surface: PTYSize?) -> Effects {
        if wait == .waiting(token) { wait = .expired }
        var effects = Effects()
        fireIfOwed(ready: surfaceReady(surface, &effects), effects: &effects)
        return effects
    }

    /// Whether `frame` goes to the PTY. A frame without a size, or any frame
    /// before a grid is declared, is written as it comes.
    public mutating func frame(_ frame: HerdrFrame, surface: PTYSize?) -> (write: Bool, effects: Effects) {
        var effects = Effects()
        guard let declared, let size = frame.size else { return (true, effects) }
        let ready = surfaceReady(surface, &effects)
        let write = size == declared && ready && (frame.full || !baselineBroken)
        if write {
            if frame.full {
                baselineBroken = false
                repaint = .none
            }
        } else {
            baselineBroken = true
            // A dropped full frame at the declared grid may be the very answer
            // a requested repaint was waiting on.
            if repaint == .none || (frame.full && size == declared) {
                repaint = .owed
            }
        }
        fireIfOwed(ready: ready, effects: &effects)
        return (write, effects)
    }

    private mutating func fireIfOwed(ready: Bool, effects: inout Effects) {
        guard repaint == .owed, ready, let declared else { return }
        repaint = .requested
        effects.resize = declared
    }

    private mutating func surfaceReady(_ surface: PTYSize?, _ effects: inout Effects) -> Bool {
        guard let declared, let surface else { return true }
        if surface == declared {
            wait = .none
            return true
        }
        switch wait {
        case .expired:
            return true
        case .waiting:
            return false
        case .none:
            waitTokens += 1
            wait = .waiting(waitTokens)
            effects.surfaceWait = waitTokens
            return false
        }
    }
}
