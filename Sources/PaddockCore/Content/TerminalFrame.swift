import Foundation

public struct TerminalFrame: Equatable, Sendable {
    public let seq: Int
    public let full: Bool
    public let width: Int
    public let height: Int
    public let bytes: Data

    public init(seq: Int, full: Bool, width: Int, height: Int, bytes: Data) {
        self.seq = seq
        self.full = full
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// The one full-frame-reset rule every terminal-feeding path must apply,
/// extracted so the headless `PaneTerminal` (tested) and the live AppKit
/// path (`PaneTerminalView`, untestable without a display) share the exact
/// same code rather than two hand-copies that can drift. `full` frames are a
/// from-scratch repaint (absolute cursor addressing), not a diff against
/// prior terminal state, so any stale cells outside what the new frame
/// touches would survive without a reset first.
public enum FrameFeeder {
    public static func feed(_ frame: TerminalFrame, reset: () -> Void, feed: (Data) -> Void) {
        if frame.full {
            reset()
        }
        feed(frame.bytes)
    }
}

/// Decoded shape of one `herdr terminal session observe` NDJSON line.
enum ObserveWireLine: Sendable {
    case frame(TerminalFrame)
    case closed
    case ignored
}

extension ObserveWireLine {
    private struct Payload: Decodable {
        let type: String
        let seq: Int?
        let width: Int?
        let height: Int?
        let full: Bool?
        let bytes: String?
    }

    /// Unknown types and frames missing a required field both fall through
    /// to `.ignored`, matching the wire tolerance the brief requires.
    static func parse(_ line: Data) -> ObserveWireLine {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: line) else { return .ignored }
        switch payload.type {
        case "terminal.frame":
            guard let seq = payload.seq, let width = payload.width, let height = payload.height,
                  let full = payload.full, let base64 = payload.bytes,
                  let decoded = Data(base64Encoded: base64)
            else { return .ignored }
            return .frame(TerminalFrame(seq: seq, full: full, width: width, height: height, bytes: decoded))
        case "terminal.closed":
            return .closed
        default:
            return .ignored
        }
    }
}
