import GhosttyKit
import XCTest
@testable import FlockCore

/// Runs the scratch config text through real libghostty the way
/// `GhosttyHost.configureNextSurface` does, because that is the only thing that
/// says whether a key is spelled the way libghostty reads it. A key libghostty
/// rejects lands in the config's diagnostics, and `configureNextSurface` then
/// refuses to create the surface at all, so a typo here costs every pane its
/// terminal with nothing printed anywhere.
final class GhosttyConfigTextAcceptanceTests: XCTestCase {
    func testLibghosttyAcceptsEveryKeyInTheScratchConfig() throws {
        XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), 0)
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)

        let colors = GhosttyThemeColors(
            background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
            foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
            ansi: Array(repeating: GhosttyThemeColor(red: 0, green: 0, blue: 0), count: 16)
        )
        let text = GhosttyThemeConfig.configText(
            colors: colors, commandArgv: ["/path/to/Flock", "--bridge", "w1:p1"],
            fontFamily: "Menlo", fontSizePoints: 13.0, optionAsAlt: .left
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-config-acceptance-\(UUID().uuidString.prefix(8)).ghostty")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let before = ghostty_config_diagnostics_count(config)
        file.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        XCTAssertEqual(
            ghostty_config_diagnostics_count(config), before,
            "libghostty rejected something in:\n\(text)"
        )
    }

    /// The four literal values `OptionAsAlt.configValue` can produce are
    /// libghostty's own enum members for this key
    /// (`Vendor/ghostty/src/input/config.zig`'s `OptionAsAlt`); this pins that
    /// every one is still spelled the way libghostty's config parser reads it.
    func testLibghosttyAcceptsEveryOptionAsAltValue() throws {
        XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), 0)
        let colors = GhosttyThemeColors(
            background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
            foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
            ansi: Array(repeating: GhosttyThemeColor(red: 0, green: 0, blue: 0), count: 16)
        )
        for value in OptionAsAlt.allCases {
            let config = try XCTUnwrap(ghostty_config_new())
            defer { ghostty_config_free(config) }
            ghostty_config_finalize(config)

            let text = GhosttyThemeConfig.configText(
                colors: colors, commandArgv: ["/path/to/Flock", "--bridge", "w1:p1"],
                fontFamily: "Menlo", fontSizePoints: 13.0, optionAsAlt: value
            )
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("flock-config-acceptance-\(value.rawValue)-\(UUID().uuidString.prefix(8)).ghostty")
            try text.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            let before = ghostty_config_diagnostics_count(config)
            file.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            XCTAssertEqual(
                ghostty_config_diagnostics_count(config), before,
                "libghostty rejected macos-option-as-alt = \(value.configValue) in:\n\(text)"
            )
        }
    }
}
