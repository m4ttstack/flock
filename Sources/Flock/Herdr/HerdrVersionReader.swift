import Foundation

/// Runs `<binary> --version` and returns what it printed, nil when it could
/// not run, exited non-zero or missed the deadline. Synchronous because the
/// probe it feeds is; the store's fingerprint check keeps it to once per
/// binary change. Output goes to a file rather than a pipe, so a descendant
/// holding the descriptor cannot keep the read open.
struct HerdrVersionReader: Sendable {
    var deadline: TimeInterval = 5
    var environment: @Sendable () -> [String: String] = { ToolPath.childEnvironment() }

    func read(binaryPath: String) -> String? {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("flock-herdr-version-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        guard FileManager.default.createFile(atPath: log.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard exited.wait(timeout: .now() + deadline) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? String(contentsOf: log, encoding: .utf8)
    }
}
