import Foundation

/// The CPU a patched herdr binary is built for. A patch is published per
/// architecture, and the one installed must match the Mac's own CPU.
public enum HerdrPatchArch: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    /// The Mac's CPU, not this process's: a universal Flock opened under
    /// Rosetta on Apple silicon must still install the arm64 herdr.
    public static var current: HerdrPatchArch {
        #if arch(x86_64)
            isTranslated ? .arm64 : .x86_64
        #else
            .arm64
        #endif
    }

    private static var isTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }
}

/// One installable patch: a herdr version built for one architecture, at one
/// revision of flock's patch for that version.
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let sha256: String
    public let arch: HerdrPatchArch
    public let revision: Int
    /// The SHA-256 of every earlier revision published for this version and
    /// architecture: a herdr carrying one of them has an outdated patch.
    public let superseded: Set<String>
    /// The patch changes herdr's server as well as its per-pane client, so
    /// it is whole only once the running server is on the patched binary.
    public let changesServer: Bool

    public init(
        version: String, sha256: String, arch: HerdrPatchArch = .current, revision: Int = 1, superseded: Set<String> = [],
        changesServer: Bool = false
    ) {
        self.version = version
        self.sha256 = sha256
        self.arch = arch
        self.revision = revision
        self.superseded = superseded
        self.changesServer = changesServer
    }

    /// Revision 1 carries no suffix: its releases were published before
    /// revisions existed, under the bare version.
    public var releaseName: String { revision == 1 ? version : "\(version)-r\(revision)" }

    public var fileName: String { "herdr-mouse-patch-\(releaseName)-\(arch.rawValue)" }

    public var url: URL {
        URL(string: "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(releaseName)/\(fileName)")!
    }

    /// Whether `installed` is the SHA-256 of an earlier revision of this patch.
    public func supersedes(sha256 installed: String?) -> Bool {
        installed.map(superseded.contains) ?? false
    }
}

/// A herdr-patch release and the SHA-256 of each architecture it carries. A
/// nil SHA-256 is a build not published, or not pinned yet, for that
/// architecture, and the catalog skips it.
public struct HerdrMousePatchRelease: Equatable, Sendable {
    public let version: String
    public let revision: Int
    public let sha256: [HerdrPatchArch: String]
    public let changesServer: Bool

    public init(version: String, revision: Int = 1, arm64: String?, x86_64: String? = nil, changesServer: Bool = false) {
        self.version = version
        self.revision = revision
        self.changesServer = changesServer
        var sha256: [HerdrPatchArch: String] = [:]
        sha256[.arm64] = arm64
        sha256[.x86_64] = x86_64
        self.sha256 = sha256
    }

    public func entry(for arch: HerdrPatchArch, superseded: Set<String> = []) -> HerdrMousePatchEntry? {
        sha256[arch].map {
            HerdrMousePatchEntry(
                version: version, sha256: $0, arch: arch, revision: revision, superseded: superseded, changesServer: changesServer
            )
        }
    }
}

/// The herdr patches this flock trusts. A version is patchable on this Mac
/// only if one of its releases carries this architecture, and only a download
/// matching that SHA-256 is ever installed. Adding a herdr version, or a new
/// revision of a version's patch, is a flock release: build, publish, add one
/// line. A version's newest pinned revision is the one offered.
public enum HerdrMousePatchCatalog {
    /// The pin for a build that is not published yet. Until the published
    /// SHA-256 replaces it, the previous revision stays the one offered.
    public static let awaitingPublication: String? = nil

    public static let releases: [HerdrMousePatchRelease] = [
        HerdrMousePatchRelease(version: "0.9.1", arm64: "535cc07b2f8f617439acac9720104fa791ee62926e6669df75b89f37e6e4cfec"),
        HerdrMousePatchRelease(version: "0.9.2", arm64: "4d24edb6e6ad17b257a1ff22e72c51997c47934da24f2645ea9ede89b2bd1c31"),
        HerdrMousePatchRelease(version: "0.9.3", arm64: "c9660a5510697ffefff67669cfdb9991bb53eedac91ff11f2040289ac36700ff"),
        HerdrMousePatchRelease(version: "0.9.4", arm64: "b7191225e2b4fd7c699e081ff3d37d5ff2886213d03aea54e94ea44289e66c89"),
        HerdrMousePatchRelease(
            version: "0.9.5", arm64: "630d0d0f462b0094bb1383273220288584fca71e7127d70e6308e799160b33eb",
            x86_64: "80c2c47fe595bcdee342abb063e6e969ddbcf0c1008eef1c3e168e1701041b72"
        ),
        HerdrMousePatchRelease(
            version: "0.9.5", revision: 2, arm64: "e5ae358c87d039b9b7edb8cf9071a718ce2c9f9f781f795f3e9309e2dc3e5786",
            x86_64: "c1e4b5b2999044ec333aa29a518aab52cfe2373bb3a5f7de8db3a52447035aa4",
            changesServer: true
        ),
    ]

    /// The patches that can run on this Mac.
    public static var entries: [HerdrMousePatchEntry] { entries(for: .current) }

    /// One entry per version: its newest revision built for `arch`.
    public static func entries(
        for arch: HerdrPatchArch, in releases: [HerdrMousePatchRelease] = releases
    ) -> [HerdrMousePatchEntry] {
        var versions: [String] = []
        for release in releases where !versions.contains(release.version) {
            versions.append(release.version)
        }
        return versions.compactMap { entry(for: $0, arch: arch, in: releases) }
    }

    public static func entry(for version: String) -> HerdrMousePatchEntry? {
        entry(for: version, arch: .current)
    }

    public static func entry(
        for version: String, arch: HerdrPatchArch, in releases: [HerdrMousePatchRelease] = releases
    ) -> HerdrMousePatchEntry? {
        let pinned = releases
            .filter { $0.version == version && $0.sha256[arch] != nil }
            .sorted { $0.revision < $1.revision }
        guard let newest = pinned.last else { return nil }
        return newest.entry(for: arch, superseded: Set(pinned.dropLast().compactMap { $0.sha256[arch] }))
    }
}
