import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// A herdr machine's folder sheet: the panes' folders over the listed
/// folder's subfolders, and a folder the machine doesn't have, in a dark and
/// a light theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class MachineFolderSheetRenderTests: XCTestCase {
    func testPanesFoldersLeadTheListing() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            for (name, path) in [("listed", "/Users/acme/code"), ("missing", "/Users/acme/gone")] {
                let browser = MachineFolderBrowser { path in
                    guard path == "/Users/acme/code" else { throw MachineFolderBrowser.NoSuchFolder() }
                    return MachineFolderListing(path: "/Users/acme/code", subfolders: ["acme-api", "acme-web", "dotfiles", "training-plan"])
                }
                await browser.go(to: path)
                let view = MachineFolderSheet(
                    theme: theme, message: "Where \"training\" opens",
                    suggestions: ["/Users/acme/code/training-plan", "/Users/acme/code/acme-web"],
                    browser: browser, onChoose: { _ in }, onCancel: {}
                )
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: MachineFolderSheet.size), styleMask: [.borderless],
                    backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.colorSpace = .sRGB
                window.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
                window.contentView = NSHostingView(rootView: view)
                defer { window.close() }
                for _ in 0..<6 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                }
                let view2 = try XCTUnwrap(window.contentView)
                let rep = try XCTUnwrap(view2.bitmapImageRepForCachingDisplay(in: view2.bounds))
                view2.cacheDisplay(in: view2.bounds, to: rep)
                if let directory {
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("machine-folder-\(name)-\(scheme).png"))
                }
                let corner = try XCTUnwrap(rep.colorAt(x: 6, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                let chrome = theme.palette.chromeRoles.chrome
                XCTAssertEqual(Int((corner.redComponent * 255).rounded()), chrome.red, accuracy: 2, "\(scheme) \(name): the sheet sits on chrome")
            }
        }
    }
}
