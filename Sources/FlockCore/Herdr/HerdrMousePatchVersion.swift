import Foundation

/// Whether a herdr binary's own bytes report the one version this build's
/// patch is made for. Scope for this build is a single version only; any
/// other reports "not covered" with no attempt to say what it actually is.
///
/// rustc packs adjacent string literals in `.rodata` with no separating byte,
/// so a naive substring search for "0.9.1" also lights up inside "0.9.12" or
/// "1.0.9.1". `matches` requires a digit or `.` on neither side of the
/// version string, so a longer number never reads as a match.
public enum HerdrMousePatchVersion {
    public static let supported = "0.9.1"

    /// A herdr binary runs past 20 MB and Settings probes it on the main
    /// thread, so the search is `Data.range(of:)` (`memmem`), never a walk
    /// over every byte offset, which takes seconds in a Debug build.
    public static func matches(_ version: String, in data: Data) -> Bool {
        let needle = Data(version.utf8)
        guard !needle.isEmpty else { return false }

        func isVersionByte(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: ".")
        }

        var searchStart = data.startIndex
        while let hit = data.range(of: needle, in: searchStart..<data.endIndex) {
            let clearBefore = hit.lowerBound == data.startIndex || !isVersionByte(data[hit.lowerBound - 1])
            let clearAfter = hit.upperBound == data.endIndex || !isVersionByte(data[hit.upperBound])
            if clearBefore, clearAfter { return true }
            searchStart = hit.lowerBound + 1
        }
        return false
    }
}
