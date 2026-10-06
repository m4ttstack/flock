import Foundation

public struct RepoBranch: Equatable, Sendable {
    public let repo: String
    public let branch: String?

    public init(repo: String, branch: String?) {
        self.repo = repo
        self.branch = branch
    }

    public var text: String { branch.map { "\(repo) @ \($0)" } ?? repo }
}

/// A folder's repository and branch from the files git leaves on disk, like
/// `MainCheckout`: it runs on every mission-control refresh, so it may cost a
/// few file reads but never a git process.
public enum RepoBranchReader {
    public static func read(folder: String) -> RepoBranch {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        guard let checkout = MainCheckout.resolve(from: folder) else { return RepoBranch(repo: name, branch: nil) }
        let head = gitDirectory(from: folder).flatMap { try? String(contentsOf: $0.appendingPathComponent("HEAD"), encoding: .utf8) }
        return RepoBranch(repo: URL(fileURLWithPath: checkout).lastPathComponent, branch: head.flatMap(branch(head:)))
    }

    public static func branch(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = "ref: refs/heads/"
        if line.hasPrefix(local) { return String(line.dropFirst(local.count)) }
        if line.hasPrefix("ref: ") { return line.split(separator: "/").last.map(String.init) }
        if line.count == 40, line.allSatisfy(\.isHexDigit) { return String(line.prefix(7)) }
        return nil
    }

    /// The git directory holding this folder's own HEAD: `.git` itself in a
    /// main checkout, the `gitdir` a linked worktree's `.git` file names.
    static func gitDirectory(from folder: String) -> URL? {
        var directory = URL(fileURLWithPath: folder, isDirectory: true).standardized
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
                else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                return raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw, isDirectory: true).standardized
                    : directory.appendingPathComponent(raw, isDirectory: true).standardized
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }
}

/// One read per folder until the view that shows them opens again.
@MainActor
public final class RepoBranchCache {
    private var entries: [String: RepoBranch] = [:]
    private let read: (String) -> RepoBranch

    public init(read: @escaping (String) -> RepoBranch = RepoBranchReader.read(folder:)) {
        self.read = read
    }

    public func repoBranch(for folder: String) -> RepoBranch {
        if let hit = entries[folder] { return hit }
        let value = read(folder)
        entries[folder] = value
        return value
    }

    public func invalidate() {
        entries.removeAll()
    }
}
