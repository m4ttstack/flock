import Foundation

/// `rt run --resolve-only`'s printed result (`RunResolveResult` in rt's
/// `commands/run.ts`).
public struct RunResolveResult: Decodable, Equatable, Sendable {
    public let targetDir: String
    public let packageLabel: String
    public let worktree: String
    public let branch: String
    public let commandTemplate: String
    public let script: String

    public init(targetDir: String, packageLabel: String, worktree: String, branch: String, commandTemplate: String, script: String) {
        self.targetDir = targetDir
        self.packageLabel = packageLabel
        self.worktree = worktree
        self.branch = branch
        self.commandTemplate = commandTemplate
        self.script = script
    }
}

/// The two files one rt item's typed lines write, named by the item's token.
/// Their paths reach the pane through the env its tab was created with.
public struct RtFilePaths: Equatable, Sendable {
    public let out: URL
    public let status: URL
    public let seed: URL

    public init(token: String, directory: URL) {
        out = directory.appendingPathComponent("\(token).out")
        status = directory.appendingPathComponent("\(token).status")
        seed = directory.appendingPathComponent("\(token).seed")
    }
}

public protocol RtFileStore: Sendable {
    func read(_ url: URL) -> String?
    func write(_ text: String, to url: URL)
    func delete(_ url: URL)
    func prepareDirectory(_ url: URL)
}

public struct DiskRtFileStore: RtFileStore {
    public init() {}

    public func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func prepareDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public enum RtFileParse {
    public static func status(_ text: String?) -> Int32? {
        text.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func runResult(_ text: String?) -> RunResolveResult? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(RunResolveResult.self, from: Data(trimmed.utf8))
    }

    /// A queue or preset picked under `--resolve-only`: flock checks only the
    /// shape holds a row to seed a runner with; rt reads the rows themselves.
    public static func seed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let envelope = try? JSONDecoder().decode(SeedEnvelope.self, from: Data(trimmed.utf8)),
              !envelope.seed.isEmpty
        else { return nil }
        return trimmed
    }

    private struct SeedEnvelope: Decodable {
        struct Row: Decodable {
            let name: String
            let command: String
            let cwd: String
        }

        let seed: [Row]
    }
}
