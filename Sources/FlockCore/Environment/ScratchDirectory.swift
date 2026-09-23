import Foundation

/// flock's own directory for the short-lived files it makes on the main
/// actor: each pane's FIFOs and the config file libghostty loads a surface
/// from. Not `$TMPDIR` itself, which other tools can fill with hundreds of
/// thousands of entries; creating a file there then costs hundreds of
/// milliseconds, and far longer under load, where a small directory stays
/// well under one.
public enum ScratchDirectory {
    /// Falls back to the temp directory itself if the subdirectory cannot be
    /// made, which is slower but still works.
    public static let url: URL = {
        let temp = FileManager.default.temporaryDirectory
        let url = temp.appendingPathComponent("flock-scratch-\(geteuid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return temp
        }
    }()
}
