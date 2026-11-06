import Foundation

public enum MachineResolveError: Error, Equatable {
    case noServer
    case unknownSession
    case failed(String)
}

/// ssh argument lists for a machine's tunnel. Remote commands go through
/// `sh -c` because the remote login shell may be zsh or fish.
public enum MachineSSH {
    public static let remotePasteDirectory = "/tmp/flock-paste"

    /// Same rule as herdr's `shell_quote`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellCommand(_ script: String) -> String {
        "sh -c " + shellQuote(script)
    }

    public static func resolveArguments(target: String) -> [String] {
        let script = "H=$(command -v herdr 2>/dev/null || echo \"$HOME/.local/bin/herdr\"); \"$H\" session list --json"
        return ["-o", "BatchMode=yes", target, shellCommand(script)]
    }

    public static func remoteAPISocket(from entries: [HerdrSessionEntry], session: String) throws -> String {
        let match = entries.first { session == "default" ? $0.isDefault : $0.name == session }
        guard let match else { throw MachineResolveError.unknownSession }
        guard match.isRunning else { throw MachineResolveError.noServer }
        return match.socketPath
    }

    /// ssh writes its reason for failing as the last line of stderr.
    public static func lastLine(of output: Data) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    public static func remoteClientSocket(apiSocket: String) -> String {
        let directory = (apiSocket as NSString).deletingLastPathComponent
        return directory + "/herdr-client.sock"
    }

    public static func forwardArguments(target: String, paths: MachineTunnelPaths, remoteAPISocket: String) -> [String] {
        let remoteClient = remoteClientSocket(apiSocket: remoteAPISocket)
        return ["-N",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "StreamLocalBindUnlink=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-L", "\(paths.apiSocket):\(remoteAPISocket)",
                "-L", "\(paths.clientSocket):\(remoteClient)",
                target]
    }

    public static func uploadArguments(target: String, remotePath: String) -> [String] {
        let script = "mkdir -p \(remotePasteDirectory) && cat > \(shellQuote(remotePath))"
        return ["-o", "BatchMode=yes", target, shellCommand(script)]
    }
}
