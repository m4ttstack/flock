import CoreText
import Foundation
import FlockCore
import Observation

/// The terminal font face the ghostty surface loads (via
/// `GhosttyThemeConfig`'s `font-family` config line): the family the user's
/// own terminal is configured with when CoreText resolves it, else the
/// fallback below. "SF Mono" -- what SwiftUI's
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
    /// Resolved once per launch: a font change in the terminal's own config
    /// lands on the next launch rather than mid-session, which keeps every
    /// pane's cell metrics stable for the life of the process.
    public static let face: String = resolve()

    /// Where the terminal flock mirrors keeps its own config.
    private static var terminalConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/config")
    }

    private static func resolve() -> String {
        let text = try? String(contentsOf: terminalConfigURL, encoding: .utf8)
        return TerminalFontResolution.face(configText: text) { family in
            // CoreText answers a name it cannot resolve with Helvetica rather
            // than with nil, so the family name has to be read back.
            let font = CTFontCreateWithName(family as CFString, 13, nil)
            return (CTFontCopyFamilyName(font) as String) == family
        }
    }
}

/// One of three fixed terminal point sizes: the font size every pane renders
/// at, outright. It is never fitted down -- the size decides the cell, the
/// cell decides how many whole cells a pane's box holds, and that grid is
/// what flock asks herdr for.
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

    public var larger: TerminalTextSize? {
        let all = Self.allCases
        let next = all.index(after: all.firstIndex(of: self)!)
        return next < all.endIndex ? all[next] : nil
    }

    public var smaller: TerminalTextSize? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index > all.startIndex ? all[all.index(before: index)] : nil
    }
}

/// Holds the active terminal text size, persisted across launches, mirroring
/// `ThemeStore`'s own UserDefaults pattern. Injected via the SwiftUI
/// environment (`.environment(terminalTextSizeStore)`); views read it with
/// `@Environment(TerminalTextSizeStore.self)`.
@MainActor
@Observable
public final class TerminalTextSizeStore {
    public static let defaultsKey = "flock.terminalTextSize"

    public private(set) var active: TerminalTextSize

    /// The size every surface renders at, as libghostty's `font-size` wants it.
    public var points: Double { Double(active.points) }

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

/// The rt modal's terminal text size, one per rt command and kept apart from
/// the panes', so glitter can read smaller than nav. A type of its own so the
/// environment can carry both stores.
@MainActor
@Observable
public final class RtModalTextSizeStore {
    public static func defaultsKey(for kind: RtKind) -> String { "flock.rtModalTextSize.\(kind.rawValue)" }

    public private(set) var sizes: [RtKind: TerminalTextSize]

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        sizes = Dictionary(uniqueKeysWithValues: RtKind.allCases.map { kind in
            let storedID = userDefaults.string(forKey: Self.defaultsKey(for: kind))
            return (kind, storedID.flatMap(TerminalTextSize.init(rawValue:)) ?? .regular)
        })
    }

    public func size(for kind: RtKind) -> TerminalTextSize { sizes[kind] ?? .regular }

    public func points(for kind: RtKind) -> Double { Double(size(for: kind).points) }

    public func select(_ size: TerminalTextSize, for kind: RtKind) {
        sizes[kind] = size
        userDefaults.set(size.rawValue, forKey: Self.defaultsKey(for: kind))
    }
}
