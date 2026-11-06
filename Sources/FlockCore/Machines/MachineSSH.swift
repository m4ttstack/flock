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

    /// Writes stdin to `fileName` in the remote user's own paste directory
    /// and prints the path written. Another user on the machine may have
    /// planted that directory's name, so an existing one is used only if it
    /// is a real directory the remote user owns; inside it no one else can
    /// plant a file, and noclobber refuses to write through one regardless.
    public static func uploadScript(fileName: String) -> String {
        [
            "umask 077",
            "t=${TMPDIR:-/tmp}",
            "d=${t%/}/flock-paste-$(id -u)",
            "if ! mkdir -m 700 \"$d\" 2>/dev/null; then "
                + "if [ -L \"$d\" ] || [ ! -d \"$d\" ] || [ ! -O \"$d\" ]; then "
                + "echo \"flock: $d is not a private directory\" >&2; exit 1; fi; "
                + "chmod 700 \"$d\" || exit 1; fi",
            "f=\"$d\"/\(shellQuote(fileName))",
            "set -C",
            "cat > \"$f\" || exit 1",
            "printf '%s\\n' \"$f\"",
        ].joined(separator: "; ")
    }

    public static func uploadArguments(target: String, fileName: String) -> [String] {
        ["-o", "BatchMode=yes", "--", target, shellCommand(uploadScript(fileName: fileName))]
    }

    /// The path `uploadScript` printed. A login shell's startup files can
    /// write to stdout first, so only the last line counts.
    public static func uploadedPath(from stdout: Data) -> String? {
        let last = String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
        guard let last, last.hasPrefix("/") else { return nil }
        return last
    }
}
