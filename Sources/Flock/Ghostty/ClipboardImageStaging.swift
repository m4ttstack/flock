import Foundation
import os

private let stagingLog = Logger(subsystem: "dev.mattstack.flock", category: "clipboard")

/// Where clipboard image bytes go when nothing on the clipboard points at a
/// file. A paste carries text and only text, so bytes need a path on disk
/// before they can be pasted at all.
///
/// What lands here is the user's own screen capture, so the file is
/// owner-only inside an owner-only directory. Nothing deletes it at paste
/// time: the program the path was handed to may read it at any point
/// afterwards, so the only reaper is the age sweep every stage runs.
enum ClipboardImageStaging {
    /// Old enough that whatever the path was pasted into has long since read
    /// the file. herdr stages clipboard images for its own client under the
    /// same policy.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("flock-clipboard-images-\(geteuid())", isDirectory: true)
    }

    /// The absolute path the bytes now live at, or nil if they could not be
    /// written, in which case there is nothing to paste for this item.
    static func stage(_ data: Data, fileExtension: String) -> String? {
        guard let directory = ensureDirectory() else { return nil }
        sweepStale(in: directory)

        let unique = DispatchTime.now().uptimeNanoseconds
        for attempt in 0..<100 {
            let url = directory.appendingPathComponent("clipboard-\(unique)-\(attempt).\(fileExtension)")
            let descriptor = createExclusively(at: url)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                stagingLog.warning("cannot stage a clipboard image at \(url.path, privacy: .public): errno \(errno)")
                return nil
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try file.write(contentsOf: data)
                try file.close()
                return url.path
            } catch {
                try? FileManager.default.removeItem(at: url)
                stagingLog.warning(
                    "cannot write a clipboard image: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        stagingLog.warning("cannot find a free name for a clipboard image in \(directory.path, privacy: .public)")
        return nil
    }

    /// `O_EXCL` so a name already in use is never written over, and the mode
    /// at creation so the bytes are never briefly readable by anyone else.
    private static func createExclusively(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
    }

    private static func ensureDirectory() -> URL? {
        let directory = directory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Creation attributes apply only to a directory this call creates,
            // so an existing one keeps whatever mode it was left with.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory
        } catch {
            stagingLog.warning(
                "clipboard image staging is unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func sweepStale(in directory: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maximumAge)
        for entry in entries {
            guard
                let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                modified < cutoff
            else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
