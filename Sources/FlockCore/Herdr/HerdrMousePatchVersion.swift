import Foundation

/// Which of the herdr versions this build carries a patch for a binary's own
/// bytes report, if any. Any other version reports "not covered" with no
/// attempt to say what it actually is.
///
/// rustc packs adjacent string literals in `.rodata` with no separating byte,
/// so a naive substring search for "0.9.1" also lights up inside "0.9.12" or
/// "1.0.9.1". `matches` requires a digit or `.` on neither side of the
/// version string, so a longer number never reads as a match.
///
/// herdr also embeds cargo registry paths of its dependencies
/// (`somecrate-0.9.1/src/lib.rs`), which carry versions that are not herdr's.
/// A hit shaped like one of those never counts, and a binary naming more than
/// one catalogue version is ambiguous, so it reads as not covered rather than
/// as whichever version happens to come first.
public enum HerdrMousePatchVersion {
    public static var supported: [String] { HerdrMousePatchCatalog.entries.map(\.version) }

    public static func detect(in data: Data) -> String? {
        let found = supported.filter { matches($0, in: data) }
        return found.count == 1 ? found[0] : nil
    }

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
            let before = hit.lowerBound == data.startIndex ? nil : data[hit.lowerBound - 1]
            let after = hit.upperBound == data.endIndex ? nil : data[hit.upperBound]
            let clearBefore = before.map { !isVersionByte($0) } ?? true
            let clearAfter = after.map { !isVersionByte($0) } ?? true
            let isCratePath = before == UInt8(ascii: "-") && after == UInt8(ascii: "/")
            if clearBefore, clearAfter, !isCratePath { return true }
            searchStart = hit.lowerBound + 1
        }
        return false
    }
}
