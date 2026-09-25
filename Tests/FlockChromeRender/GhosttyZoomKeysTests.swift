import GhosttyKit
import XCTest
@testable import FlockCore

/// flock owns the terminal font size, so libghostty must not keep its own
/// zoom keys: a Cmd-plus the View menu lets through would otherwise resize a
/// surface under the grid flock asked herdr for.
@MainActor
final class GhosttyZoomKeysTests: XCTestCase {
    private static let actions = ["increase_font_size:1", "decrease_font_size:1", "reset_font_size"]

    func testFlocksSurfaceConfigUnbindsEveryFontSizeKey() throws {
        _ = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        for action in Self.actions {
            XCTAssertTrue(isBound(action, in: config), "libghostty no longer binds \(action) by default")
        }

        let text = GhosttyThemeConfig.configText(
            colors: GhosttyThemeColors(
                background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
                foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
                ansi: Array(repeating: GhosttyThemeColor(red: 128, green: 128, blue: 128), count: 16)
            ),
            commandArgv: ["/usr/bin/true"], fontFamily: "Menlo", fontSizePoints: 13, optionAsAlt: .left
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-zoom-keys-\(UUID().uuidString.prefix(8)).ghostty")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        file.path.withCString { ghostty_config_load_file(config, $0) }

        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0, "libghostty rejected a line of:\n\(text)")
        for action in Self.actions {
            XCTAssertFalse(isBound(action, in: config), "\(action) is still bound")
        }
    }

    private func isBound(_ action: String, in config: ghostty_config_t) -> Bool {
        let trigger = action.withCString { ghostty_config_trigger(config, $0, UInt(strlen($0))) }
        return !(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL && trigger.key.physical == GHOSTTY_KEY_UNIDENTIFIED)
    }
}
