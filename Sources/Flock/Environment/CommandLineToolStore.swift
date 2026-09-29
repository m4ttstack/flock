import FlockCore
import Foundation
import Observation

/// Drives the Settings row that links `flock` into `~/.local/bin`. The link names the binary inside the app bundle, so it
/// survives Sparkle updates and dev-build swaps, which replace the bundle in
/// place.
@MainActor
@Observable
final class CommandLineToolStore {
    private(set) var state: CommandLineToolState = .notInstalled
    private(set) var lastErrorMessage: String?

    let name: String
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let executablePath: String
    @ObservationIgnored private let fileManager: FileManager

    var linkPath: String {
        (directory.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath
    }

    private var link: URL { directory.appendingPathComponent(name) }

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
        executablePath: String = Bundle.main.executablePath ?? "",
        name: String = CommandLineTool.name,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.executablePath = executablePath
        self.name = name
        self.fileManager = fileManager
        refresh()
    }

    func refresh() {
        let exists = (try? fileManager.attributesOfItem(atPath: link.path)) != nil
        state = CommandLineTool.state(
            exists: exists,
            linkTarget: try? fileManager.destinationOfSymbolicLink(atPath: link.path),
            isFlock: { [executablePath] target in
                if target == executablePath { return true }
                let app = URL(fileURLWithPath: target)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                return Bundle(url: app)?.bundleIdentifier.map(FlockClientGuard.flockBundleIDs.contains) ?? false
            }
        )
    }

    func performAction() {
        lastErrorMessage = nil
        do {
            switch state {
            case .notInstalled:
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: executablePath)
            case .installed:
                try fileManager.removeItem(at: link)
            case .otherLink:
                try fileManager.removeItem(at: link)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: executablePath)
            case .otherFile:
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refresh()
    }
}
