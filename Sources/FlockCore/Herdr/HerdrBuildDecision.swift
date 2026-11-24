import Foundation

/// Where this Mac's herdr stands against the mattstack build list.
public enum HerdrBuildState: Equatable, Sendable {
    case missing(installPath: String)
    /// Not a mattstack build, and one flock can replace.
    case stock(installPath: String, installed: String?, newest: String)
    /// A mattstack or flock-patched build older than the list's newest.
    case outdated(installPath: String, installed: String?, newest: String)
    case current(version: String)
    case notWritable(installPath: String)
    /// The list could not be read, or has no build for this Mac's CPU.
    case listUnavailable(installed: String?)
}

public enum HerdrBuildDecision {
    public static func decide(
        binaryExists: Bool, version: HerdrBuildVersion?, sha256: String?, list: HerdrBuildList?, arch: HerdrArch,
        installPath: String, isWritable: Bool
    ) -> HerdrBuildState {
        guard binaryExists else { return isWritable ? .missing(installPath: installPath) : .notWritable(installPath: installPath) }
        guard let list, let newestAsset = list.newest.assets[arch] else {
            return .listUnavailable(installed: version?.display)
        }
        let newest = list.newest.version
        if let sha256, sha256 == newestAsset.sha256 { return .current(version: newest.display) }
        if let version, version.isMattstackBuild, !version.isOlder(than: newest) {
            return .current(version: version.display)
        }
        let outdated = version?.isMattstackBuild == true || list.isOutdatedBuild(sha256: sha256)
        guard isWritable else { return .notWritable(installPath: installPath) }
        return outdated
            ? .outdated(installPath: installPath, installed: version?.display, newest: newest.display)
            : .stock(installPath: installPath, installed: version?.display, newest: newest.display)
    }
}
