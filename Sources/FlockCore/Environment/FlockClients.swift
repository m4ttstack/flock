import Foundation

/// One running Flock and the herdr session it attaches to.
///
/// Two Flocks on one session fight: each takes control of every visible pane
/// and sizes it to its own window. So every Flock leaves a record of which
/// session it is on, and one that opens onto a session another already holds
/// can say so before it attaches.
public struct FlockClientRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let appName: String
    public let socketPath: String

    public init(pid: Int32, bundleID: String, appName: String, socketPath: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.socketPath = FlockClientRecord.normalized(socketPath)
    }

    /// One session reached by two spellings of its path is still one session.
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// A running Flock process as the workspace reports it, record or not.
public struct RunningFlock: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let appName: String

    public init(pid: Int32, bundleID: String, appName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// The records, one file per process, in a directory every flavor shares.
public struct FlockClientRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Flock/clients`, named outright rather
    /// than derived from the bundle so Flock and Flock Dev read one list.
    public static var shared: FlockClientRegistry {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FlockClientRegistry(directory: support.appendingPathComponent("Flock/clients", isDirectory: true))
    }

    public func register(_ record: FlockClientRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(for: record.pid), options: .atomic)
    }

    public func unregister(pid: Int32) {
        try? FileManager.default.removeItem(at: file(for: pid))
    }

    public func records() -> [FlockClientRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(FlockClientRecord.self, from: Data(contentsOf: $0)) }
    }

    private func file(for pid: Int32) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }
}

public enum FlockClientConflict {
    /// Every other running Flock attached to `socketPath`.
    ///
    /// A record whose process is no longer running is left over from a crash
    /// and ignored. A running Flock with no record predates the registry, and
    /// those builds could only reach the default session unless launched with
    /// an override, so it is taken to be there.
    public static func others(
        attachedTo socketPath: String, selfPID: Int32, records: [FlockClientRecord],
        running: [RunningFlock], defaultSocketPath: String
    ) -> [RunningFlock] {
        let session = FlockClientRecord.normalized(socketPath)
        let fallback = FlockClientRecord.normalized(defaultSocketPath)
        let recorded = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        return running.filter { flock in
            guard flock.pid != selfPID else { return false }
            return (recorded[flock.pid]?.socketPath ?? fallback) == session
        }
    }
}
