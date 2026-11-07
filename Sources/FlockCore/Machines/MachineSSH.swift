import Foundation

public enum MachineResolveError: Error, Equatable {
    case noServer
    case unknownSession
    case failed(String)
}

/// ssh argument lists for a machine's tunnel. Remote commands go through
/// `sh -c` because the remote login shell may be zsh or fish.
public enum MachineSSH {
    /// Same rule as herdr's `shell_quote`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellCommand(_ script: String) -> String {
        "sh -c " + shellQuote(script)
    }

    public static func resolveArguments(target: String) -> [String] {
        let script = "H=$(command -v herdr 2>/dev/null || echo \"$HOME/.local/bin/herdr\"); \"$H\" session list --json"
        return ["-o", "BatchMode=yes", "--", target, shellCommand(script)]
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
                "--", target]
    }

    static let uploadedPathMarker = "flock-paste:"

    /// Writes stdin to `fileName` in a new directory and prints the path
    /// after `uploadedPathMarker`. Any fixed name in a shared temp directory
    /// can be planted or swapped by another user, so every upload gets its
    /// own from mktemp, which creates it atomically with mode 0700.
    /// `fileName` must already be shell-neutral (`ClipboardPaste.remoteFileName`):
    /// fish reads backslashes inside single quotes, so quoting alone is not.
    public static func uploadScript(fileName: String) -> String {
        [
            "umask 077",
            "t=${TMPDIR:-/tmp}",
            "d=$(mktemp -d \"${t%/}/flock-paste.XXXXXXXX\") || exit 1",
            "f=\"$d\"/\(shellQuote(fileName))",
            "cat > \"$f\" || exit 1",
            "printf '\(uploadedPathMarker)%s\\n' \"$f\"",
        ].joined(separator: "; ")
    }

    public static func uploadArguments(target: String, fileName: String) -> [String] {
        ["-o", "BatchMode=yes", "--", target, shellCommand(uploadScript(fileName: fileName))]
    }

    /// The path `uploadScript` printed. A login shell's startup files can
    /// write to stdout first, without a trailing newline, so the path is
    /// what follows the marker on the last line that has one.
    public static func uploadedPath(from stdout: Data) -> String? {
        let line = String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last { $0.contains(uploadedPathMarker) }
        guard let line, let marker = line.range(of: uploadedPathMarker) else { return nil }
        let path = String(line[marker.upperBound...])
        return path.hasPrefix("/") ? path : nil
    }
}
