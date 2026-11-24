import FlockCore
import Foundation
import os

private let pastedImageLog = Logger(subsystem: "dev.mattstack.flock", category: "pasted-images")

/// `PastedImageIndex` on disk, so labels keep their images across launches.
///
/// Flock's own staged clipboard images are copied in, since staging reaps
/// them after a day; any other file is only pointed at. What lands here is
/// the user's own screen captures, so it is owner-only.
@MainActor
final class PastedImageStore {
    static let shared = PastedImageStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.mattstack.Flock", isDirectory: true)
            .appendingPathComponent("pasted-images", isDirectory: true),
        stagingDirectory: ClipboardImageStaging.directory
    )

    private let directory: URL
    private let stagingDirectory: URL
    private var index = PastedImageIndex()

    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL, stagingDirectory: URL, now: Date = Date()) {
        self.directory = directory
        self.stagingDirectory = stagingDirectory
        guard let data = try? Data(contentsOf: indexFile) else { return }
        do {
            index = try JSONDecoder().decode(PastedImageIndex.self, from: data)
        } catch {
            pastedImageLog.warning("cannot read the pasted image index: \(error.localizedDescription, privacy: .public)")
            return
        }
        let before = index
        index.prune(now: now)
        if index != before { save() }
        removeUnusedCopies()
    }

    /// Everything in this directory is a copy made here. At launch alone: a
    /// copy whose label was just taken over may still be wanted back.
    private func removeUnusedCopies() {
        let live = Set(index.livePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.lastPathComponent != indexFile.lastPathComponent
            && !live.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A conversation still on screen keeps its images.
    func touch(_ conversation: String, now: Date = Date()) {
        if index.touch(conversation, now: now) { save() }
    }

    func images(for conversation: String) -> [Int: String] {
        index.images(for: conversation)
    }

    /// The path the image is kept at from here on.
    func keep(_ path: String, as number: Int, in conversation: String, now: Date = Date()) -> String {
        guard ensureDirectory() else { return path }
        let kept = path.hasPrefix(stagingDirectory.path + "/") ? copy(path) ?? path : path
        index.set(kept, as: number, in: conversation, now: now)
        save()
        return kept
    }

    private func copy(_ path: String) -> String? {
        let source = URL(fileURLWithPath: path)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { return target.path }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target.path
        } catch {
            pastedImageLog.warning("cannot keep a pasted image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            pastedImageLog.warning("pasted images cannot be kept: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(index).write(to: indexFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexFile.path)
        } catch {
            pastedImageLog.warning("cannot save the pasted image index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
