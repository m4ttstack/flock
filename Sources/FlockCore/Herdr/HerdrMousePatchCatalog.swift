import Foundation

/// The CPU a patched herdr binary is built for. A patch is published per
/// architecture, and only the one matching this process can run here.
public enum HerdrPatchArch: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    public static var current: HerdrPatchArch {
        #if arch(x86_64)
            .x86_64
        #else
            .arm64
        #endif
    }
}

/// One installable patch: a herdr version built for one architecture.
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let sha256: String
    public let arch: HerdrPatchArch

    public init(version: String, sha256: String, arch: HerdrPatchArch = .current) {
        self.version = version
        self.sha256 = sha256
        self.arch = arch
    }

    public var fileName: String { "herdr-mouse-patch-\(version)-\(arch.rawValue)" }

    public var url: URL {
        URL(string: "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(version)/\(fileName)")!
    }
}

/// A herdr-patch-X release and the SHA-256 of each architecture it carries.
public struct HerdrMousePatchRelease: Equatable, Sendable {
    public let version: String
    public let sha256: [HerdrPatchArch: String]

    public init(version: String, arm64: String, x86_64: String? = nil) {
        self.version = version
        var sha256 = [HerdrPatchArch.arm64: arm64]
        sha256[.x86_64] = x86_64
        self.sha256 = sha256
    }

    public func entry(for arch: HerdrPatchArch) -> HerdrMousePatchEntry? {
        sha256[arch].map { HerdrMousePatchEntry(version: version, sha256: $0, arch: arch) }
    }
}

/// The herdr patches this flock trusts. A version is patchable on this Mac
/// only if its release carries this architecture, and only a download
/// matching that SHA-256 is ever installed. Adding a herdr version is a flock
/// release: build, publish, add one line.
public enum HerdrMousePatchCatalog {
    public static let releases: [HerdrMousePatchRelease] = [
        HerdrMousePatchRelease(version: "0.9.1", arm64: "535cc07b2f8f617439acac9720104fa791ee62926e6669df75b89f37e6e4cfec"),
        HerdrMousePatchRelease(version: "0.9.2", arm64: "4d24edb6e6ad17b257a1ff22e72c51997c47934da24f2645ea9ede89b2bd1c31"),
        HerdrMousePatchRelease(version: "0.9.3", arm64: "c9660a5510697ffefff67669cfdb9991bb53eedac91ff11f2040289ac36700ff"),
        HerdrMousePatchRelease(version: "0.9.4", arm64: "b7191225e2b4fd7c699e081ff3d37d5ff2886213d03aea54e94ea44289e66c89"),
        HerdrMousePatchRelease(version: "0.9.5", arm64: "630d0d0f462b0094bb1383273220288584fca71e7127d70e6308e799160b33eb"),
    ]

    /// The patches that can run on this Mac.
    public static var entries: [HerdrMousePatchEntry] { entries(for: .current) }

    public static func entries(for arch: HerdrPatchArch) -> [HerdrMousePatchEntry] {
        releases.compactMap { $0.entry(for: arch) }
    }

    public static func entry(for version: String) -> HerdrMousePatchEntry? {
        entry(for: version, arch: .current)
    }

    public static func entry(for version: String, arch: HerdrPatchArch) -> HerdrMousePatchEntry? {
        releases.first { $0.version == version }?.entry(for: arch)
    }
}
