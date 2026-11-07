import Foundation
import Observation

/// One folder on a herdr machine and the folders directly inside it.
public struct MachineFolderListing: Equatable, Sendable {
    public let path: String
    public let subfolders: [String]

    public init(path: String, subfolders: [String]) {
        self.path = path
        self.subfolders = subfolders
    }

    static let pathMarker = "flock-dir:"
    static let subfolderMarker = "flock-sub:"

    /// Reads the folder from stdin rather than the command line: fish reads
    /// backslashes inside single quotes, so no quoting survives every login
    /// shell. An empty line lists the home folder. Dot folders are left out.
    public static let script = [
        "IFS= read -r p",
        "if [ -n \"$p\" ]; then cd -- \"$p\" || exit 3; else cd || exit 3; fi",
        "printf \"\(pathMarker)%s\\n\" \"$(pwd)\"",
        "for d in */; do [ -d \"$d\" ] && printf \"\(subfolderMarker)%s\\n\" \"${d%/}\"; done",
        "exit 0",
    ].joined(separator: "; ")

    public static func arguments(target: String) -> [String] {
        ["-o", "BatchMode=yes", "--", target, "sh -c " + MachineSSH.shellQuote(script)]
    }

    public static func input(for path: String?) -> Data {
        Data(((path ?? "") + "\n").utf8)
    }

    /// A login shell's startup files can write to stdout first, so only
    /// marked lines count.
    public static func parse(_ stdout: Data) -> MachineFolderListing? {
        var path: String?
        var subfolders: [String] = []
        for line in String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if let range = line.range(of: pathMarker) {
                path = String(line[range.upperBound...])
                subfolders = []
            } else if line.hasPrefix(subfolderMarker) {
                subfolders.append(String(line.dropFirst(subfolderMarker.count)))
            }
        }
        guard let path, path.hasPrefix("/") else { return nil }
        let sorted = subfolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return MachineFolderListing(path: path, subfolders: sorted)
    }

    public static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func child(_ name: String, of path: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }
}

/// The folders a machine's panes are in now, for one-click picks.
public enum MachineFolderSuggestions {
    public static func from(_ model: SessionModel?) -> [String] {
        guard let model else { return [] }
        let folders = model.panes.values.map { $0.foregroundCwd ?? $0.cwd }.filter { $0.hasPrefix("/") }
        return Array(Set(folders)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Browses a herdr machine's folders, one listing at a time. A listing that
/// lands after a newer request is dropped.
@MainActor
@Observable
public final class MachineFolderBrowser {
    public enum State: Equatable {
        case loading
        case listed
        case failed(String)
    }

    public private(set) var listing: MachineFolderListing?
    public private(set) var state: State = .loading
    /// The folder last asked for, shown while it loads.
    public private(set) var requested: String?

    @ObservationIgnored private let list: @Sendable (String?) async throws -> MachineFolderListing
    @ObservationIgnored private var sequence = 0

    public init(list: @escaping @Sendable (String?) async throws -> MachineFolderListing) {
        self.list = list
    }

    /// The folder Choose picks: the listed one, never one still loading.
    public var chosen: String? {
        state == .listed ? listing?.path : nil
    }

    /// nil lists the home folder.
    public func go(to path: String?) async {
        sequence += 1
        let mine = sequence
        requested = path
        state = .loading
        do {
            let result = try await list(path)
            guard mine == sequence else { return }
            listing = result
            requested = result.path
            state = .listed
        } catch {
            guard mine == sequence else { return }
            state = .failed(Self.describe(error, path: path))
        }
    }

    public func open(_ name: String) async {
        guard let path = listing?.path else { return }
        await go(to: MachineFolderListing.child(name, of: path))
    }

    public func goUp() async {
        guard let path = listing?.path, let parent = MachineFolderListing.parent(of: path) else { return }
        await go(to: parent)
    }

    public struct Failure: Error, Equatable {
        public let detail: String
        public init(detail: String) { self.detail = detail }
    }

    public struct NoSuchFolder: Error, Equatable {
        public init() {}
    }

    private static func describe(_ error: Error, path: String?) -> String {
        if error is NoSuchFolder { return "\(path ?? "That folder") isn't a folder on the machine." }
        if let failure = error as? Failure { return failure.detail }
        return error.localizedDescription
    }
}
