import AppKit
import FlockCore
import Foundation
import Observation
import os

/// Where the Board section's names and logo come from. A test hands the store
/// canned answers here, so nothing under test runs `rt` or reaches deck.
struct BoardSources: Sendable {
    /// `rt settings get board.workspaces --json`'s stdout and exit status, or
    /// nil when rt is not installed or did not run to an exit.
    var readSetting: @Sendable () async -> (stdout: Data, exitCode: Int32)?
    /// The logo's bytes, or nil for any failure to fetch them.
    var fetchLogo: @Sendable () async -> Data?

    static let live = BoardSources(readSetting: BoardSettingReader.read, fetchLogo: BoardLogoFetcher.fetch)
}

/// The Board section's two outside facts: which workspaces are board's, from
/// the `board.workspaces` setting, and the board app's logo, from deck.
///
/// Read at launch and again each time the app becomes active, which is as
/// often as a setting that rarely changes needs; nothing polls. The logo is
/// fetched only while there is a Board to draw it on, until one fetch
/// succeeds, and the last good one is kept in UserDefaults so a relaunch with
/// deck down still has it.
@MainActor
@Observable
final class BoardStore {
    static let logoDefaultsKey = "flock.boardLogo"
    /// The icon deck serves is under a kilobyte; anything past this is not an
    /// icon, and UserDefaults is no place to keep it.
    static let logoByteLimit = 64 * 1024

    /// nil is no Board config, which shows no section at all.
    private(set) var names: BoardWorkspaceNames?
    private(set) var logo: NSImage?

    @ObservationIgnored private let sources: BoardSources
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var hasFetchedLogo = false

    private static let log = Logger(subsystem: "dev.mattstack.flock", category: "board")

    init(sources: BoardSources = .live, userDefaults: UserDefaults = .standard) {
        self.sources = sources
        self.userDefaults = userDefaults
        logo = userDefaults.data(forKey: Self.logoDefaultsKey).flatMap(Self.decodedLogo)
    }

    /// A call that arrives while a read is running waits for that one rather
    /// than starting a second `rt`.
    func refresh() async {
        if let inFlight { return await inFlight.value }
        let task = Task {
            await self.readAndFetch()
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func readAndFetch() async {
        let read = await sources.readSetting()
        let names = read.flatMap { BoardWorkspaceNames.fromSettingsGet(stdout: $0.stdout, exitCode: $0.exitCode) }
        Self.log.log("board setting ran=\(read != nil, privacy: .public) exit=\(read?.exitCode ?? -1, privacy: .public) configured=\(names != nil, privacy: .public)")
        if names != self.names { self.names = names }
        guard names != nil, !hasFetchedLogo else { return }
        guard let data = await sources.fetchLogo(), let image = Self.decodedLogo(data) else {
            Self.log.log("board logo fetch failed; cached=\(self.logo != nil, privacy: .public)")
            return
        }
        hasFetchedLogo = true
        logo = image
        userDefaults.set(data, forKey: Self.logoDefaultsKey)
    }

    /// Bytes that do not decode to an image, deck's error page say, are no
    /// logo and are never cached.
    static func decodedLogo(_ data: Data) -> NSImage? {
        guard data.count <= logoByteLimit, let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }
}

enum BoardSettingReader {
    static let arguments = ["settings", "get", "board.workspaces", "--json"]

    @Sendable
    static func read() async -> (stdout: Data, exitCode: Int32)? {
        await RtCommand.run(arguments)
    }
}

enum BoardLogoFetcher {
    /// deck's app catalog, the same one the mattstack tray draws its tabs
    /// from.
    static let url = URL(string: "https://deck.mattstack/api/apps/board/icon")!
    static let timeout: TimeInterval = 5

    @Sendable
    static func fetch() async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
