import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// An Arrange thumbnail's handle and a mini pane showing a screen with a
/// painted background, at rest, hovered, pressed and selected, in a dark and
/// a light theme. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class GridStateWashRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 1000, height: 200)
    private static let inset: CGFloat = 16
    private static let thumbnail = CGSize(width: 220, height: 160)
    private static let pitch: CGFloat = 240
    /// Where the painted block sits inside the mini pane.
    private static let painted = CGRect(x: 20, y: 40, width: 100, height: 60)

    private struct State {
        let name: String
        let interaction: ControlInteraction
        let isActive: Bool
    }

    private static let states = [
        State(name: "rest", interaction: .rest, isActive: false),
        State(name: "hover", interaction: .hover, isActive: false),
        State(name: "pressed", interaction: .pressed, isActive: false),
        State(name: "selected", interaction: .rest, isActive: true),
    ]

    func testEachStateWashesTheWholeTileAndAPaintedBackgroundStaysFlush() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let window = host(sheet(theme), theme: theme)
            defer { window.close() }
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-state-wash-\(scheme).png"))
            }

            var grounds: [String] = [], strips: [String] = []
            for (index, state) in Self.states.enumerated() {
                let pane = Self.paneFrame(index)
                let ground = hex(image, CGPoint(x: pane.maxX - 20, y: pane.maxY - 12))
                let paint = hex(image, CGPoint(x: pane.minX + Self.painted.maxX - 10, y: pane.minY + Self.painted.maxY - 8))
                XCTAssertEqual(paint, ground, "\(scheme) \(state.name): the painted background boxes off from the ground")
                grounds.append(ground)
                let x = Self.inset + CGFloat(index) * Self.pitch
                strips.append(hex(image, CGPoint(x: x + 150, y: Self.inset + 6)))
            }
            XCTAssertEqual(grounds[0], theme.palette.chromeRoles.pane.hex, "\(scheme): a resting mini pane sits on the terminal's ground")
            XCTAssertEqual(Set(grounds).count, Self.states.count, "\(scheme): mini pane states \(grounds) must all differ")
            XCTAssertEqual(Set(strips).count, Self.states.count, "\(scheme): handle states \(strips) must all differ")

            let selected = Self.paneFrame(3)
            XCTAssertEqual(
                hex(image, CGPoint(x: selected.minX + 0.75, y: selected.midY)), theme.palette.accent.hex,
                "\(scheme): the selected wash hides the selection outline"
            )
        }
    }

    private static func paneFrame(_ index: Int) -> CGRect {
        let pad = ChromeMetrics.Grid.thumbnailPadding
        return CGRect(
            x: inset + CGFloat(index) * pitch + pad,
            y: inset + ChromeMetrics.Grid.tabStripHeight + pad,
            width: thumbnail.width - pad * 2,
            height: thumbnail.height - ChromeMetrics.Grid.tabStripHeight - pad * 2
        )
    }

    private func sheet(_ theme: Theme) -> some View {
        HStack(alignment: .top, spacing: Self.pitch - Self.thumbnail.width) {
            ForEach(Self.states.indices, id: \.self) { index in
                let state = Self.states[index]
                VStack(spacing: 0) {
                    TabHandleStrip(
                        theme: theme, title: "api", status: .working, isFocusedTab: true,
                        interaction: state.interaction, isActive: state.isActive
                    )
                    MiniPane(
                        theme: theme, title: "claude", status: .working, isSelected: state.isActive,
                        interaction: state.interaction, detail: AnyView(Self.screen(theme))
                    )
                    .padding(ChromeMetrics.Grid.thumbnailPadding)
                }
                .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
                .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
                .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.surface))
            }
        }
        .padding(Self.inset)
    }

    /// A screen whose app paints the terminal's default background over a
    /// block, as a TUI's panel does.
    private static func screen(_ theme: Theme) -> some View {
        ZStack(alignment: .topLeading) {
            Text("claude acme-api @ main")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textStrong)
                .padding(6)
            theme.terminalGround
                .frame(width: painted.width, height: painted.height)
                .overlay(alignment: .topLeading) {
                    Text("> 1. Yes\n  2. No")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .padding(4)
                }
                .offset(x: painted.minX, y: painted.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func host(_ view: some View, theme: Theme) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                theme.canvas
                view
            }
            .frame(width: Self.size.width, height: Self.size.height)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
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

    /// The pixel at a point in view space, top-left origin.
    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }
}
