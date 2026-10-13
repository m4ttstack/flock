import Foundation
import Observation

/// Which addresses a click in a pane may hand to another app without asking.
/// A pane's program chooses what it prints, so a scheme that reaches some
/// other app (`vscode://`, `ssh://`) opens only once the user has said so.
public struct LinkTrust: Equatable {
    /// The browser and the mail client, which every address in a terminal
    /// has always been allowed to reach.
    public static let builtIn: Set<String> = ["http", "https", "mailto"]

    public private(set) var schemes: Set<String>

    public init(schemes: some Sequence<String> = []) {
        self.schemes = Set(schemes.map { $0.lowercased() }).subtracting(Self.builtIn)
    }

    public func trusts(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return Self.builtIn.contains(scheme) || schemes.contains(scheme)
    }

    public mutating func trust(_ scheme: String) {
        let scheme = scheme.lowercased()
        guard !Self.builtIn.contains(scheme) else { return }
        schemes.insert(scheme)
    }

    public mutating func revoke(_ scheme: String) {
        schemes.remove(scheme.lowercased())
    }

    /// The trusted schemes as Settings lists them.
    public var listed: [String] { schemes.sorted() }
}

@MainActor
@Observable
public final class LinkTrustStore {
    public static let defaultsKey = "flock.trustedLinkSchemes"

    public private(set) var trust: LinkTrust

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        trust = LinkTrust(schemes: userDefaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func trust(_ scheme: String) {
        trust.trust(scheme)
        userDefaults.set(trust.listed, forKey: Self.defaultsKey)
    }

    public func revoke(_ scheme: String) {
        trust.revoke(scheme)
        userDefaults.set(trust.listed, forKey: Self.defaultsKey)
    }
}
