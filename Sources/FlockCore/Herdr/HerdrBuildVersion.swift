import Foundation

/// A herdr build as `herdr --version` prints it: stock `X.Y.Z`, or the
/// mattstack fork's `X.Y.Z-ms.N`. Read from that output rather than from the
/// binary's bytes, which embed other version strings.
public struct HerdrBuildVersion: Hashable, Sendable {
    public let base: String
    public let forkRevision: Int?

    public var isMattstackBuild: Bool { forkRevision != nil }

    public var display: String { forkRevision.map { "\(base)-ms.\($0)" } ?? base }

    /// A bare version string: `0.9.5` or `0.9.5-ms.2`.
    public init?(_ string: String) {
        let pieces = string.components(separatedBy: "-ms.")
        guard pieces.count <= 2 else { return nil }
        let base = pieces[0]
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy(Self.isNumber) else { return nil }
        self.base = base
        if pieces.count == 2 {
            guard Self.isNumber(Substring(pieces[1])), let revision = Int(pieces[1]), revision >= 1 else { return nil }
            forkRevision = revision
        } else {
            forkRevision = nil
        }
    }

    /// herdr prints exactly `herdr <version>`; anything else is unknown.
    public static func parse(versionOutput: String) -> HerdrBuildVersion? {
        let line = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "herdr "
        guard line.hasPrefix(prefix) else { return nil }
        return HerdrBuildVersion(String(line.dropFirst(prefix.count)))
    }

    /// Numeric per part, so `0.9.9` is older than `0.9.10`. A stock build is
    /// older than any fork build of the same base.
    public func isOlder(than other: HerdrBuildVersion) -> Bool {
        let mine = components(of: base)
        let theirs = components(of: other.base)
        if mine != theirs { return mine.lexicographicallyPrecedes(theirs) }
        return (forkRevision ?? 0) < (other.forkRevision ?? 0)
    }

    private func components(of base: String) -> [Int] {
        base.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func isNumber(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}
