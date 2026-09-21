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

    public static func matches(_ version: String, in data: Data) -> Bool {
        let needle = Array(version.utf8)
        guard !needle.isEmpty else { return false }
        let bytes = Array(data)
        guard bytes.count >= needle.count else { return false }

        func isVersionByte(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: ".")
        }

        for start in 0...(bytes.count - needle.count) {
            guard bytes[start..<(start + needle.count)].elementsEqual(needle) else { continue }
            let before = start - 1
            if before >= 0, isVersionByte(bytes[before]) { continue }
            let after = start + needle.count
            if after < bytes.count, isVersionByte(bytes[after]) { continue }
            return true
        }
        return false
    }
}
