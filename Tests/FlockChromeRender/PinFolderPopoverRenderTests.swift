import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// A new pin's folder question as its popover draws it: where the shell is
/// now, picked, over where it started, then Other, in a dark and a light
/// theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PinFolderPopoverRenderTests: XCTestCase {
    private static let size = CGSize(width: 380, height: 190)
    private static let scale: CGFloat = 2

    func testThePickedFolderLeadsAndTheOthersFollow() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let ask = PinFolderAsk(pin: PinID(rawValue: "p1"), choices: [
            PinFolderAsk.Choice(folder: "/Users/acme/code/training-plan", reason: .shellNow),
            PinFolderAsk.Choice(folder: "/Users/acme/code", reason: .shellStarted),
        ])
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let view = PinFolderPopover(theme: theme, name: "training-plan", ask: ask, onChoose: { _ in }, onOther: {})
                .padding(20)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .background(theme.pane)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(rootView: view)
            defer { window.close() }
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pin-folder-ask-\(scheme).png"))
            }
            let firstRowEdge = CGPoint(x: 20 + ChromeMetrics.PinFolderPopover.width - 4, y: 20 + 40)
            XCTAssertEqual(hex(image, firstRowEdge), theme.palette.chromeRoles.selection.hex, "\(scheme): the first choice is the picked one")
        }
    }

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
