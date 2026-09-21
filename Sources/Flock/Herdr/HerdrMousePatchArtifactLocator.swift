import FlockCore
import Foundation

/// Where `Scripts/build-herdr-patch.sh` puts the prebuilt patched herdr
/// binary: a flat, version-and-architecture-named file in the app's own
/// bundle resources (every resource under `Sources/Flock/Resources` lands
/// directly in `Contents/Resources`, with no subfolder preserved, the same
/// way `Inter-Bold.otf` does). Gitignored and never committed, so a fresh
/// clone simply has none of these files -- that reads as
/// `.artifactUnavailable`, never a crash.
enum HerdrMousePatchArtifactLocator {
    static func path(
        version: String = HerdrMousePatchVersion.supported,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent(resourceName(version: version))
        return fileManager.isReadableFile(atPath: candidate.path) ? candidate.path : nil
    }

    static func resourceName(version: String) -> String {
        "herdr-mouse-patch-\(version)-\(architecture)"
    }

    #if arch(arm64)
    private static let architecture = "arm64"
    #elseif arch(x86_64)
    private static let architecture = "x86_64"
    #else
    private static let architecture = "unknown"
    #endif
}
