import Foundation
import Observation

/// The terminal font face the ghostty surface loads (via
/// `GhosttyThemeConfig`'s `font-family` config line). "SF Mono" -- what SwiftUI's
/// `.system(design: .monospaced)` resolves to -- is NOT CoreText-discoverable
/// by family name, even with Xcode.app installed: the file exists
/// (`Xcode.app/Contents/SharedFrameworks/DVTUserInterfaceKit.framework/.../
/// Fonts/SF-Mono.ttf`), but it is a private resource Xcode/Terminal load for
/// their own UI, never registered into any system font directory or the
/// font-family catalog CoreText's name lookup searches. Confirmed on this
/// machine: `NSFont(name: "SF Mono", size:)` is `nil`, and
/// `CTFontCreateWithName("SF Mono", ...)` silently falls back to Helvetica
/// rather than failing loudly. "Menlo" is public, present at
/// `/System/Library/Fonts/Menlo.ttc`, and is the one family name ghostty's
/// own font-discovery test round-trips through `CTFontCreateWithName`
/// (`Vendor/ghostty/src/font/face/coretext.zig`) -- the pinned face for both
/// reasons.
public enum TerminalFont {
    public static let face = "Menlo"
}

/// One of three fixed terminal point sizes, applied globally to every pane
/// via the ghostty config's `font-size` line.
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
