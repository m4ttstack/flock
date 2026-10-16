import Foundation

/// The herdr patches this flock trusts. A version is patchable only if it is
/// here, and only a download matching its SHA-256 is ever installed. Adding a
/// herdr version is a flock release: build, publish, add one line.
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let sha256: String

    public init(version: String, sha256: String) {
        self.version = version
        self.sha256 = sha256
    }

    public var fileName: String { "herdr-mouse-patch-\(version)-arm64" }

    public var url: URL {
        URL(string: "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(version)/\(fileName)")!
    }
}

public enum HerdrMousePatchCatalog {
    public static let entries: [HerdrMousePatchEntry] = [
        HerdrMousePatchEntry(version: "0.9.1", sha256: "535cc07b2f8f617439acac9720104fa791ee62926e6669df75b89f37e6e4cfec"),
        HerdrMousePatchEntry(version: "0.9.2", sha256: "4d24edb6e6ad17b257a1ff22e72c51997c47934da24f2645ea9ede89b2bd1c31"),
        HerdrMousePatchEntry(version: "0.9.3", sha256: "c9660a5510697ffefff67669cfdb9991bb53eedac91ff11f2040289ac36700ff"),
        HerdrMousePatchEntry(version: "0.9.4", sha256: "b7191225e2b4fd7c699e081ff3d37d5ff2886213d03aea54e94ea44289e66c89"),
        HerdrMousePatchEntry(version: "0.9.5", sha256: "630d0d0f462b0094bb1383273220288584fca71e7127d70e6308e799160b33eb"),
    ]

    public static func entry(for version: String) -> HerdrMousePatchEntry? {
        entries.first { $0.version == version }
    }
}
