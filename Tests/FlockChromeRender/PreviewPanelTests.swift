import AppKit
@testable import FlockCore
import XCTest

/// The preview panel as it opens and closes: it is never seen anywhere but
/// its place. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PreviewPanelTests: XCTestCase {
    private func item(_ number: Int, width: Int, height: Int) throws -> PastedImageQuickLook.Item {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width / 2, height: height / 2))
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flock-preview-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return PastedImageQuickLook.Item(number: number, title: "Image \(number)", url: url, thumbnail: image)
    }

    /// Animated whatever the machine's own setting.
    private func panel(reduceMotion: Bool = false) -> PastedImageQuickLook {
        let look = PastedImageQuickLook()
        look.reduceMotion = { reduceMotion }
        return look
    }

    private func host() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    func testThePanelIsOnlyEverSeenInItsPlace() async throws {
        let window = host()
        defer { window.close() }
        let look = panel()
        let source = NSRect(x: 900, y: 240, width: 170, height: 128)
        let items = [try item(1, width: 700, height: 500), try item(2, width: 300, height: 600)]
        for dark in [true, false] {
            look.show(items, startingAt: 1, over: window, isDark: dark, sourceFrame: { _ in source }, isImage: { _ in false })
            let place = look.panel.frame
            XCTAssertGreaterThanOrEqual(place.minY, source.maxY, "not above what was clicked")
            var seen: Set<NSRect> = []
            // Past the landing, so a move right after it is seen too.
            var landed = 0
            for _ in 0..<500 where landed < 20 {
                if look.panel.isVisible, look.panel.alphaValue > 0 { seen.insert(look.panel.frame) }
                if look.panel.alphaValue == 1 { landed += 1 }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(seen, [place])
            XCTAssertEqual(look.panel.alphaValue, 1)
            try write(try XCTUnwrap(look.picture()), name: "preview-panel-\(dark ? "dark" : "light")")
            look.close()
            for _ in 0..<60 where look.panel.isVisible { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(look.panel.isVisible)
        }
    }

    func testClosingWhileItOpensLeavesNothingBehind() async throws {
        let window = host()
        defer { window.close() }
        let look = panel()
        let source = NSRect(x: 900, y: 240, width: 170, height: 128)
        look.show(
            [try item(1, width: 700, height: 500)], startingAt: 1, over: window, isDark: true,
            sourceFrame: { _ in source }, isImage: { _ in false })
        try await Task.sleep(for: .milliseconds(60))
        look.close()
        for _ in 0..<500 where look.zoom != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(look.panel.isVisible)
        XCTAssertFalse(look.isOpen)
        XCTAssertNil(look.zoom)
    }

    func testAnotherImageTakesOverAnOpenPanel() async throws {
        let window = host()
        defer { window.close() }
        let look = panel()
        let source = NSRect(x: 900, y: 240, width: 170, height: 128)
        let items = [try item(1, width: 700, height: 500), try item(2, width: 300, height: 600)]
        for number in [1, 2] {
            look.show(
                items, startingAt: number, over: window, isDark: true, sourceFrame: { _ in source },
                isImage: { _ in false })
            XCTAssertEqual(look.panel.title, "Image \(number) (\(number) of 2)")
            for _ in 0..<500 where look.panel.alphaValue < 1 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(look.panel.alphaValue, 1)
        }
        look.close()
        try await Task.sleep(for: .milliseconds(400))
    }

    func testMovingOnWhileItOpensLeavesOnlyThePanel() async throws {
        let window = host()
        defer { window.close() }
        let source = NSRect(x: 900, y: 240, width: 170, height: 128)
        let items = [try item(1, width: 700, height: 500), try item(2, width: 300, height: 600)]
        let moves: [(PastedImageQuickLook) -> Void] = [
            { $0.step(1) },
            {
                $0.show(
                    items, startingAt: 2, over: window, isDark: true, sourceFrame: { _ in source },
                    isImage: { _ in false })
            },
        ]
        for move in moves {
            let look = panel()
            look.show(
                items, startingAt: 1, over: window, isDark: true, sourceFrame: { _ in source },
                isImage: { _ in false })
            XCTAssertNotNil(look.zoom)
            move(look)
            XCTAssertNil(look.zoom)
            XCTAssertEqual(look.panel.alphaValue, 1)
            XCTAssertEqual(look.panel.title, "Image 2 (2 of 2)")
            look.close()
            for _ in 0..<500 where look.zoom != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(look.zoom)
        }
    }

    func testReduceMotionOpensAndClosesAtOnce() throws {
        let window = host()
        defer { window.close() }
        let look = panel(reduceMotion: true)
        look.show(
            [try item(1, width: 700, height: 500)], startingAt: 1, over: window, isDark: true,
            sourceFrame: { _ in NSRect(x: 900, y: 240, width: 170, height: 128) }, isImage: { _ in false })
        XCTAssertNil(look.zoom)
        XCTAssertEqual(look.panel.alphaValue, 1)
        look.close()
        XCTAssertNil(look.zoom)
        XCTAssertFalse(look.panel.isVisible)
    }

    func testTheSameImageFromAnotherWindowBelongsToThatWindow() throws {
        let (first, second) = (host(), host())
        defer { first.close() }
        let look = panel(reduceMotion: true)
        let items = [try item(1, width: 700, height: 500)]
        for window in [first, second] {
            look.show(
                items, startingAt: 1, over: window, isDark: true,
                sourceFrame: { _ in NSRect(x: 900, y: 240, width: 170, height: 128) }, isImage: { _ in false })
        }
        second.close()
        XCTAssertFalse(look.isOpen)
    }

    func testAPhotoTakenSidewaysIsShownUpright() throws {
        let plain = try item(1, width: 70, height: 50)
        XCTAssertEqual(PastedImageQuickLook.fullImage(at: plain.url)?.width, 70)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(plain.url as CFURL, nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flock-preview-\(UUID().uuidString).jpg")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(file, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(file))
        let shown = try XCTUnwrap(PastedImageQuickLook.fullImage(at: url))
        XCTAssertEqual([shown.width, shown.height], [50, 70])
    }

    private func write(_ image: NSImage, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !folder.isEmpty else { return }
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
