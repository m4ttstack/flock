import Foundation

/// Which herdr server a window talks to: herdr's default, one of its named
/// sessions, or a socket at a path herdr does not manage.
public enum HerdrServerAddress: Equatable, Sendable {
    case defaultServer
    case named(String)
    case custom(String)

    private static let sessionsDirectory = "/.config/herdr/sessions/"
    private static let defaultRelativePath = "/.config/herdr/herdr.sock"
    private static let socketFileName = "herdr.sock"

    /// Lexical only, never touches the filesystem: a leading `~` becomes
    /// `home`, `.` and `..` components are resolved, duplicate and trailing
    /// slashes are dropped.
    public static func normalize(_ path: String, home: String) -> String {
        var expanded = path
        if path == "~" || path.hasPrefix("~/") {
            expanded = home + path.dropFirst()
        }
        var parts: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return expanded.hasPrefix("/") ? "/" + joined : joined
    }

    public init(socketPath: String, home: String) {
        let path = Self.normalize(socketPath, home: home)
        let root = Self.normalize(home, home: home)
        if path == root + Self.defaultRelativePath {
            self = .defaultServer
            return
        }
        let sessions = root + Self.sessionsDirectory
        if path.hasPrefix(sessions) {
            let rest = path.dropFirst(sessions.count).split(separator: "/", omittingEmptySubsequences: false)
            if rest.count == 2, rest[1] == Self.socketFileName, Self.isValidSessionName(String(rest[0])) {
                self = .named(String(rest[0]))
                return
            }
        }
        self = .custom(path)
    }

    public func socketPath(home: String) -> String {
        let root = Self.normalize(home, home: home)
        switch self {
        case .defaultServer: return root + Self.defaultRelativePath
        case .named(let name): return root + Self.sessionsDirectory + name + "/" + Self.socketFileName
        case .custom(let path): return path
        }
    }

    /// The default server, the session name, or the custom socket's parent
    /// directory name.
    public var label: String {
        switch self {
        case .defaultServer: return "default"
        case .named(let name): return name
        case .custom(let path):
            return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }
    }

    /// herdr can only start servers it names; a custom socket is attach-only.
    public var isStartable: Bool {
        if case .custom = self { return false }
        return true
    }

    /// herdr reserves `default` for the unnamed server.
    public static func isValidSessionName(_ name: String) -> Bool {
        name != "default"
            && name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }
}
