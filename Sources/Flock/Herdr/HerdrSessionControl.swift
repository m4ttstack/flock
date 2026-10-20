import FlockCore
import Foundation

/// Stops or deletes one named herdr session with `herdr session stop|delete`.
enum HerdrSessionControl {
    enum Failure: Error, Equatable {
        case notFound
        case invalidName(String)
        /// herdr's own message, or the fallback when it gave none.
        case herdr(String)

        var message: String {
            switch self {
            case .notFound: HerdrServerLauncher.Failure.notFound.message
            case .invalidName(let name): "\"\(name)\" isn't a herdr server name."
            case .herdr(let message): message
            }
        }
    }

    static func stop(name: String) async -> Result<Void, Failure> {
        await run("stop", name: name)
    }

    static func delete(name: String) async -> Result<Void, Failure> {
        await run("delete", name: name)
    }

    private static func run(_ verb: String, name: String) async -> Result<Void, Failure> {
        guard HerdrServerAddress.isValidSessionName(name) else { return .failure(.invalidName(name)) }
        // Resolving the PATH can block on the login shell probe.
        let prepared = await Task.detached { () -> (binary: String, environment: [String: String])? in
            guard let binary = ToolPath.resolve("herdr") else { return nil }
            // The name alone picks the session; a socket in the environment
            // would point herdr at the current one instead.
            var environment = ToolPath.childEnvironment()
            environment.removeValue(forKey: "HERDR_SOCKET_PATH")
            return (binary, environment)
        }.value
        guard let prepared else { return .failure(.notFound) }
        let fallback = "herdr couldn't \(verb) \"\(name)\"."
        let runner = ToolRunner(binaryPath: prepared.binary, environment: prepared.environment, deadline: .seconds(10))
        guard let result = try? await runner.runCapturingStderr(["session", verb, name, "--json"]) else {
            return .failure(.herdr(fallback))
        }
        guard result.exitCode == 0 else {
            return .failure(.herdr(HerdrServerActions.failureMessage(stderr: result.stderr, fallback: fallback)))
        }
        return .success(())
    }
}
