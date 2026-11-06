import Foundation

/// A `flock://open` link: the board asking for a new tab in an MR's
/// worktree. It runs a command in a shell, so it is honored only with the
/// token from the file only this user can read.
public struct FlockOpenLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case shell, claude, resume, command

        /// The kinds that start Claude, which a pin's account applies to.
        public var isClaude: Bool { self == .claude || self == .resume }
    }

    public enum Refusal: Error, Equatable {
        case notAnOpenLink
        case missing(String)
        case badToken
        case unknownKind(String)
        case notAFolder(String)

        public var message: String {
            switch self {
            case .notAnOpenLink: "Flock can't open that link."
            case .missing(let field): "The board's link to Flock had no \(field)."
            case .badToken: "Flock ignored a link that didn't come from the board."
            case .unknownKind(let kind): "Flock doesn't know how to open \"\(kind)\"."
            case .notAFolder(let path): "\(path) isn't a folder, so Flock opened nothing."
            }
        }
    }

    public static let scheme = "flock"

    public let folder: String
    public let repo: String
    public let label: String
    public let kind: Kind
    /// nil for an empty shell.
    public let run: String?

    public init(folder: String, repo: String, label: String, kind: Kind, run: String?) {
        self.folder = folder
        self.repo = repo
        self.label = label
        self.kind = kind
        self.run = run
    }

    public static func isOpenLink(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == "open"
    }

    public static func parse(
        _ url: URL, expectedToken: String?, isFolder: (String) -> Bool
    ) -> Result<FlockOpenLink, Refusal> {
        guard isOpenLink(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notAnOpenLink)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        guard let expectedToken, !expectedToken.isEmpty, query["token"] == expectedToken else {
            return .failure(.badToken)
        }
        for field in ["folder", "repo", "label", "kind"] where (query[field] ?? "").isEmpty {
            return .failure(.missing(field))
        }
        let rawKind = query["kind"]!
        guard let kind = Kind(rawValue: rawKind) else { return .failure(.unknownKind(rawKind)) }
        let folder = query["folder"]!
        guard isFolder(folder) else { return .failure(.notAFolder(folder)) }
        let run = query["run"].flatMap { $0.isEmpty ? nil : $0 }
        if kind != .shell, run == nil { return .failure(.missing("command")) }
        return .success(FlockOpenLink(folder: folder, repo: query["repo"]!, label: query["label"]!, kind: kind, run: run))
    }

    /// The line typed into the new pane: a Claude kind under a pin's cswap
    /// account becomes `cswap run <n>`, with resume's own arguments after
    /// `--`. `accountLine` is what `ClaudeAccountLaunch` made of the account.
    public func paneLine(accountLine: String?) -> String? {
        guard let run else { return nil }
        guard kind.isClaude, let accountLine, accountLine != ClaudeAccountLaunch.claudeBinary else { return run }
        let claudePrefix = ClaudeAccountLaunch.claudeBinary + " "
        guard run.hasPrefix(claudePrefix) else { return accountLine }
        return "\(accountLine) -- \(run.dropFirst(claudePrefix.count))"
    }
}

/// The shared secret behind `flock://open`. The board reads the same file,
/// and whichever side gets there first creates it.
public enum FlockOpenToken {
    public static func path(home: String) -> String {
        (home as NSString).appendingPathComponent(".mattstack/flock/open-token")
    }

    public static func readOrCreate(home: String) -> String? {
        let path = path(home: home)
        if let token = read(path) { return token }
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let created = FileManager.default.createFile(
            atPath: path, contents: Data("\(token)\n".utf8), attributes: [.posixPermissions: 0o600]
        )
        // Lost a race with the board, which wrote its own between the read and the create.
        return created ? read(path) ?? token : read(path)
    }

    private static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }
}

/// Which pin, if any, a link's repo belongs to: the first in rail order whose
/// folder shares the repo's git common dir, so a pin on the main checkout
/// or on any worktree of it counts.
public enum FlockOpenPinMatch {
    public static func pin(
        for repo: String, in pins: [PinnedWorkspace], commonDir: (String) -> String?
    ) -> PinnedWorkspace? {
        guard let target = commonDir(repo) else { return nil }
        return pins.first { commonDir($0.folder) == target }
    }

    /// `git rev-parse --git-common-dir`, absolute; nil outside a repo.
    public static func gitCommonDir(of folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : (path as NSString).standardizingPath
    }
}
