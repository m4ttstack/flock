import FlockCore
import Foundation

/// Copies bytes to a path on a herdr machine over ssh.
struct RemoteFileUploader: Sendable {
    static let deadline: Duration = .seconds(15)

    struct Failure: Error, Equatable {
        let detail: String
    }

    let target: String
    /// What the machine is called in a failure note.
    let label: String
    private let send: @Sendable (Data, String) async throws -> Void

    init(target: String, label: String) {
        self.target = target
        self.label = label
        send = { data, remotePath in
            try await Self.ssh(data, to: remotePath, target: target)
        }
    }

    init(target: String, label: String, send: @escaping @Sendable (Data, String) async throws -> Void) {
        self.target = target
        self.label = label
        self.send = send
    }

    func upload(_ data: Data, to remotePath: String) async throws {
        try await send(data, remotePath)
    }

    private static func ssh(_ data: Data, to remotePath: String, target: String) async throws {
        // Resolving the PATH can block on the login shell probe.
        let environment = await Task.detached { ToolPath.childEnvironment() }.value
        let runner = ToolRunner(binaryPath: SSHTunnelProcess.sshPath, environment: environment, deadline: deadline)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runner.runCapturingStderr(
                MachineSSH.uploadArguments(target: target, remotePath: remotePath), input: data
            )
        } catch ToolRunner.Failure.timedOut {
            throw Failure(detail: "Timed out.")
        } catch {
            throw Failure(detail: error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            throw Failure(detail: MachineSSH.lastLine(of: result.stderr) ?? "ssh exited with status \(result.exitCode).")
        }
    }
}

/// Where a machine session's pastes go and where its failures are told.
struct RemotePasteTarget {
    let uploader: RemoteFileUploader
    let notify: @MainActor (String) -> Void
}
