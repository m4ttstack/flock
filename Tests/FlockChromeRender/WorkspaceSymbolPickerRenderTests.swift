import AppKit
import FlockCore
import SwiftUI
import XCTest

/// The symbol picker popover's content in a dark and a light theme, with one
/// symbol selected. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class WorkspaceSymbolPickerRenderTests: XCTestCase {
    private static let themes = [("dark", Theme(.tokyoNight)), ("light", Theme(.tokyoNightDay))]
    private static let selected = "leaf.fill"
    private static let inset: CGFloat = 12

    private var directory: String? {
        ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testTheSymbolPickerRendersInDarkAndLight() async throws {
        ChromeType.install()
        for (scheme, theme) in Self.themes {
            let picker = WorkspaceSymbolPicker(
                theme: theme, current: Self.selected, isAutomatic: false, onPick: { _ in }
            )
            let fitting = NSHostingView(rootView: picker).fittingSize
            XCTAssertEqual(fitting.width, ChromeMetrics.SymbolPicker.width, accuracy: 0.5, "\(scheme): the picker's width")
            let metrics = ChromeMetrics.SymbolPicker.self
            XCTAssertLessThanOrEqual(
                fitting.height, metrics.maxGridHeight + metrics.automaticHeight + metrics.sectionGap + 2 * metrics.padding,
                "\(scheme): the grid scrolls past its cap"
            )
            let size = CGSize(width: fitting.width + 2 * Self.inset, height: fitting.height + 2 * Self.inset)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(
                rootView: ZStack { theme.pane; picker }.frame(width: size.width, height: size.height)
            )
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("symbol-picker-\(scheme).png"))
            }
            window.close()
        }
    }

    private func snapshot(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        view.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
}
