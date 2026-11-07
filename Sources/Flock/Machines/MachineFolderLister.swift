import FlockCore
import Foundation

/// Lists a herdr machine's folders over ssh.
struct MachineFolderLister: Sendable {
    static let deadline: Duration = .seconds(15)

    let target: String

    func list(_ path: String?) async throws -> MachineFolderListing {
        // Resolving the PATH can block on the login shell probe.
        let environment = await Task.detached { ToolPath.childEnvironment() }.value
        let runner = ToolRunner(binaryPath: SSHTunnelProcess.sshPath, environment: environment, deadline: Self.deadline)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runner.runCapturingStderr(
                MachineFolderListing.arguments(target: target), input: MachineFolderListing.input(for: path)
            )
        } catch ToolRunner.Failure.timedOut {
            throw MachineFolderBrowser.Failure(detail: "The machine didn't answer in time.")
        }
        if result.exitCode == 3 { throw MachineFolderBrowser.NoSuchFolder() }
        guard result.exitCode == 0 else {
            throw MachineFolderBrowser.Failure(
                detail: MachineSSH.lastLine(of: result.stderr) ?? "ssh exited with status \(result.exitCode)."
            )
        }
        guard let listing = MachineFolderListing.parse(result.stdout) else {
            throw MachineFolderBrowser.Failure(detail: "The machine's answer couldn't be read.")
        }
        return listing
    }
}
