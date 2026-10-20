import FlockCore
import Foundation

/// The sessions herdr knows about, from `herdr session list --json`.
enum HerdrSessionLister {
    /// Nil when herdr is missing, fails, misses the deadline or answers with
    /// something else.
    static func list() async -> [HerdrSessionEntry]? {
        // Resolving the PATH can block on the login shell probe.
        let prepared = await Task.detached { () -> (binary: String, environment: [String: String])? in
            guard let binary = ToolPath.resolve("herdr") else { return nil }
            // The list is the same whichever server is current; a socket in
            // the environment would only point herdr at one of them.
            var environment = ToolPath.childEnvironment()
            environment.removeValue(forKey: "HERDR_SOCKET_PATH")
            return (binary, environment)
        }.value
        guard let prepared else { return nil }
        let runner = ToolRunner(binaryPath: prepared.binary, environment: prepared.environment, deadline: .seconds(5))
        guard let result = try? await runner.run(["session", "list", "--json"]), result.exitCode == 0 else { return nil }
        return HerdrSessionList.parse(result.stdout)
    }
}
