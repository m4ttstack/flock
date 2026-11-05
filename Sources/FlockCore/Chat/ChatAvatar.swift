import Foundation

/// What `rt chat avatar --json` prints for a handle with a face. An rt without
/// the verb, and a face that could not be drawn, both decode to nil.
public struct ChatAvatar: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case slack
        case generated
    }

    public let kind: Kind
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    public static func arguments(handle: String, size: Int) -> [String] {
        ["chat", "avatar", handle, "--size", String(size), "--json"]
    }

    public static func decode(stdout: Data, exitCode: Int32) -> ChatAvatar? {
        guard exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(ChatAvatar.self, from: stdout)
    }

    /// A Slack handle's generated face stands in until rt has the photo.
    public func isFinal(for handle: String) -> Bool {
        kind == .slack || !handle.hasPrefix("slack.")
    }
}

/// Slack pads a narrow portrait into a square with pale side bars. These match
/// `face-zoom.ts` in the chat app, so a photo is framed the same in both.
public enum ChatFaceZoom {
    public static let sampleSize = 48
    private static let pale: UInt8 = 235
    private static let opaqueEnough: UInt8 = 16
    private static let barShare = 0.97
    private static let minimumBar = 0.05
    private static let maximumZoom = 1.8

    /// How far to zoom so the side bars fall outside the frame, from
    /// `sampleSize` square RGBA pixels, row by row.
    public static func zoom(rgba: [UInt8]) -> Double {
        let size = sampleSize
        guard rgba.count == size * size * 4 else { return 1 }
        var bar = 0
        while bar < size / 2, columnIsBlank(rgba, bar), columnIsBlank(rgba, size - 1 - bar) {
            bar += 1
        }
        let share = Double(bar) / Double(size)
        return share < minimumBar ? 1 : min(1 / (1 - 2 * share), maximumZoom)
    }

    private static func columnIsBlank(_ rgba: [UInt8], _ x: Int) -> Bool {
        let size = sampleSize
        let blank = (0..<size).filter { y in
            let offset = (y * size + x) * 4
            let isClear = rgba[offset + 3] < opaqueEnough
            return isClear || rgba[offset...(offset + 2)].allSatisfy { $0 > pale }
        }
        return Double(blank.count) / Double(size) >= barShare
    }
}
