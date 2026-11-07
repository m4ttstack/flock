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
                let image = try snapshot(window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("machine-folder-\(name)-\(scheme).png"))
                }
                XCTAssertEqual(
                    hex(image, CGPoint(x: 4, y: MachineFolderSheet.size.height / 2)), theme.palette.chromeRoles.chrome.hex,
                    "\(scheme) \(name): the sheet sits on chrome"
                )
            }
        }
    }

    private static let scale: CGFloat = 2

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * Self.scale), height: Int(bounds.height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.scale, y: Self.scale)
        view.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
}
