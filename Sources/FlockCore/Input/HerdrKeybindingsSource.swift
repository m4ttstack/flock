import Foundation

/// Where herdr looks for its own `config.toml`, so flock reads the file herdr
/// is reading rather than a guess at it.
public enum HerdrConfigLocation {
    public static func path(environment: [String: String], home: String) -> String {
        if let override = environment["HERDR_CONFIG_PATH"], !override.isEmpty {
            return override
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return "\(xdg)/herdr/config.toml"
        }
        return "\(home)/.config/herdr/config.toml"
    }
}

/// What tells a config file apart from its own earlier self.
public struct HerdrConfigStamp: Equatable, Sendable {
    public var modified: Date
    public var size: Int

    public init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }
}

/// Holds the keymap read from herdr's config and re-reads it once the file on
/// disk has changed.
///
/// There is no file watcher: herdr's config directory carries its own
/// continuously-appended logs and session state, so a directory watch there
/// would fire constantly. This checks the one file instead, on a throttle, so
/// the cost is bounded no matter how fast the keys come.
@MainActor
public final class HerdrKeybindingsSource {
    private let stamp: () -> HerdrConfigStamp?
    private let contents: () -> String?
    private let now: () -> Date
    private let interval: TimeInterval

    private var loaded = HerdrKeybindings.defaults
    private var loadedStamp: HerdrConfigStamp?
    private var hasLoaded = false
    private var lastChecked: Date?

    public init(
        interval: TimeInterval = 0.25,
        now: @escaping () -> Date = Date.init,
        stamp: @escaping () -> HerdrConfigStamp?,
        contents: @escaping () -> String?
    ) {
        self.interval = interval
        self.now = now
        self.stamp = stamp
        self.contents = contents
    }

    public func current() -> HerdrKeybindings {
        let now = self.now()
        if let lastChecked, now.timeIntervalSince(lastChecked) < interval {
            return loaded
        }
        lastChecked = now
        let stamp = self.stamp()
        guard !hasLoaded || stamp != loadedStamp else { return loaded }
        hasLoaded = true
        loadedStamp = stamp
        loaded = HerdrKeybindings.read(configText: contents() ?? "")
        return loaded
    }
}
