import Foundation

/// What `rt chat avatar --json` answered: a face, no face for this handle, or
/// no such verb in this rt.
public enum ChatAvatarAnswer: Equatable, Sendable {
    case face(ChatAvatar)
    case noFace
    case noVerb
}

/// What `rt chat avatar --json` prints for a handle with a face.
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
        guard case let .face(avatar) = answer(stdout: stdout, exitCode: exitCode) else { return nil }
        return avatar
    }

    /// Anything that is not the verb's JSON is an rt without the verb, which
    /// prints its usage instead.
    public static func answer(stdout: Data, exitCode: Int32) -> ChatAvatarAnswer {
        if exitCode == 0, let avatar = try? JSONDecoder().decode(ChatAvatar.self, from: stdout) {
            return .face(avatar)
        }
        return (try? JSONDecoder().decode(Reply.self, from: stdout)) == nil ? .noVerb : .noFace
    }

    private struct Reply: Decodable {
        let ok: Bool
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
