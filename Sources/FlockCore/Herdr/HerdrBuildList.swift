import Foundation

/// The mattstack herdr fork's published build list (`herdr-builds.json`).
/// Only a download matching a SHA-256 in this list is ever installed.
public struct HerdrBuildList: Equatable, Sendable {
    public static let url = URL(string: "https://github.com/m4ttstack/herdr/releases/latest/download/herdr-builds.json")!

    private static let downloadPrefix = "https://github.com/m4ttstack/herdr/releases/download/"

    public struct Asset: Equatable, Sendable {
        public let url: URL
        public let sha256: String
    }

    public struct Build: Equatable, Sendable {
        public let version: HerdrBuildVersion
        /// The build changes herdr's server as well as its per-pane client.
        public let changesServer: Bool
        public let assets: [HerdrArch: Asset]
        /// The SHA-256 of every earlier build's assets.
        public let supersedes: Set<String>
    }

    public let newest: Build
    public let builds: [Build]
    /// The SHA-256 of every herdr build flock patched itself before the fork.
    public let flockPatchSha256: Set<String>

    private struct AssetDTO: Decodable {
        let url: String
        let sha256: String
    }

    private struct BuildDTO: Decodable {
        let version: String
        let changesServer: Bool
        let assets: [String: AssetDTO]
        let supersedes: [String]
    }

    private struct ListDTO: Decodable {
        let schema: Int
        let newest: String
        let builds: [BuildDTO]
        let flockPatchSha256: [String]
    }

    public static func decode(_ data: Data) -> HerdrBuildList? {
        guard let dto = try? JSONDecoder().decode(ListDTO.self, from: data), dto.schema == 1 else { return nil }
        var builds: [Build] = []
        for entry in dto.builds {
            guard let version = HerdrBuildVersion(entry.version), entry.supersedes.allSatisfy(isSha256) else { return nil }
            var assets: [HerdrArch: Asset] = [:]
            for (key, asset) in entry.assets {
                guard let arch = HerdrArch(rawValue: key) else { continue }
                guard isSha256(asset.sha256), asset.url.hasPrefix(downloadPrefix), let url = URL(string: asset.url) else {
                    return nil
                }
                assets[arch] = Asset(url: url, sha256: asset.sha256)
            }
            builds.append(Build(
                version: version, changesServer: entry.changesServer, assets: assets, supersedes: Set(entry.supersedes)
            ))
        }
        guard dto.flockPatchSha256.allSatisfy(isSha256),
              let newest = builds.first(where: { $0.version.display == dto.newest }) else { return nil }
        return HerdrBuildList(newest: newest, builds: builds, flockPatchSha256: Set(dto.flockPatchSha256))
    }

    /// The build named by `version` or, failing that, one carrying `sha256`.
    public func build(matching version: HerdrBuildVersion?, sha256: String?) -> Build? {
        if let version, let match = builds.first(where: { $0.version == version }) { return match }
        guard let sha256 else { return nil }
        return builds.first { $0.assets.values.contains { $0.sha256 == sha256 } }
    }

    /// Whether `sha256` is a build the newest one replaces, fork or flock-patched.
    public func isOutdatedBuild(sha256: String?) -> Bool {
        guard let sha256 else { return false }
        return newest.supersedes.contains(sha256) || flockPatchSha256.contains(sha256)
    }

    private static func isSha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
