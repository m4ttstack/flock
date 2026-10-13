import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Settings' trusted link types, which sits below the General tab's fold and
/// so is drawn here by itself, empty and filled, in both appearances. PNGs
/// are written only when `FLOCK_SETTINGS_RENDER_DIR` is set.
@MainActor
final class LinkTrustSettingsRenderTests: XCTestCase {
    private static let size = CGSize(width: 560, height: 260)

    private func store(_ schemes: [String]) throws -> LinkTrustStore {
        let name = "flock.tests.linkTrustRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store = LinkTrustStore(userDefaults: defaults)
        schemes.forEach(store.trust)
        return store
    }

    private func render(_ store: LinkTrustStore, _ appearance: NSAppearance.Name, name: String) async throws -> NSBitmapImageRep {
        let form = Form { LinkTrustSettingsSection(store: store) }
            .formStyle(.grouped)
            .frame(width: Self.size.width, height: Self.size.height)
        let hosting = NSHostingView(rootView: form)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_SETTINGS_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("settings-link-trust-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// A row per scheme is the only thing that makes the filled list taller
    /// than the empty one's single line.
    func testEveryTrustedSchemeGetsARow() async throws {
        for (appearance, label) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let empty = try await render(try store([]), appearance, name: "empty-\(label)")
            let filled = try await render(try store(["vscode", "ssh", "zed"]), appearance, name: "filled-\(label)")
            XCTAssertNotEqual(
                empty.representation(using: .png, properties: [:]), filled.representation(using: .png, properties: [:]),
                "\(label): three trusted schemes drew the same as none"
            )
        }
    }
}
