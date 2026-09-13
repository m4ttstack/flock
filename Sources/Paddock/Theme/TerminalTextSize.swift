import Foundation
import Observation

/// The one terminal font face both renderers load: the ghostty surface (via
/// `GhosttyThemeConfig`'s `font-family` config line) and the deep-history
/// overlay (`Font.custom`/`NSFont`). "SF Mono" -- what SwiftUI's
/// `.system(design: .monospaced)` resolves to -- is not a CoreText-
/// discoverable family name on a stock macOS install: it ships privately
/// inside Xcode.app/Terminal.app, never into `/System/Library/Fonts`, and
/// ghostty's own font-discovery test only round-trips `CTFontCreateWithName`
/// against "Menlo" (`Vendor/ghostty/src/font/face/coretext.zig`), which is
/// also the one confirmed present at `/System/Library/Fonts/Menlo.ttc` on
/// this machine. "Menlo" is the pinned face for that reason.
public enum TerminalFont {
    public static let face = "Menlo"
}

/// One of three fixed terminal point sizes, applied globally to every pane:
/// the ghostty config's `font-size` line and the history overlay's
/// `Font.custom` size must always agree, since the deep-history browse
/// boundary (`HistoryBrowseView`) is meant to be a color-only seam, never a
/// glyph-size jump.
public enum TerminalTextSize: String, CaseIterable, Sendable {
    case compact
    case regular
    case large

    public var points: Int {
        switch self {
        case .compact: return 11
        case .regular: return 13
        case .large: return 15
        }
    }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }
}

/// Holds the active terminal text size, persisted across launches, mirroring
/// `ThemeStore`'s own UserDefaults pattern. Injected via the SwiftUI
/// environment (`.environment(terminalTextSizeStore)`); views read it with
/// `@Environment(TerminalTextSizeStore.self)`.
@MainActor
@Observable
public final class TerminalTextSizeStore {
    public static let defaultsKey = "paddock.terminalTextSize"

    public private(set) var active: TerminalTextSize

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedID = userDefaults.string(forKey: Self.defaultsKey)
        active = storedID.flatMap(TerminalTextSize.init(rawValue:)) ?? .regular
    }

    public func select(_ size: TerminalTextSize) {
        active = size
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey)
    }
}
