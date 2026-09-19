import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The tab strip's new-tab hover affordance: a tab-shaped preview in the
/// empty run past the last tab, drawn only while hovered.
@MainActor
final class NewTabAffordanceRenderTests: XCTestCase {
    private static let workspace = WorkspaceID(rawValue: "w1")

    /// `ChromeType.newTabSymbolName` names an SF Symbol by string; a name
    /// that does not exist renders as nothing, silently, so this is what
    /// actually proves the glyph draws.
    func testTheAffordancesGlyphNameResolves() {
        XCTAssertNotNil(
            NSImage(systemSymbolName: ChromeType.newTabSymbolName, accessibilityDescription: nil),
            ChromeType.newTabSymbolName
        )
    }

    /// `tabLabels` must never be empty: `WorkspaceRecord.activeTabID` is not
    /// optional, so every fixture built here needs at least one real tab to
    /// point at.
    private func model(tabLabels: [String]) -> SessionModel {
        let tabs = tabLabels.enumerated().map { index, label in
            TabRecord(
                tabID: TabID(rawValue: "w1:t\(index + 1)"), workspaceID: Self.workspace, label: label,
                number: index + 1, paneCount: 1, agentStatus: .idle
            )
        }
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: Self.workspace, focusedTabID: tabs[0].tabID, focusedPaneID: nil,
            workspaces: [
                WorkspaceRecord(
                    workspaceID: Self.workspace, label: "flock", number: 1,
                    activeTabID: tabs[0].tabID, agentStatus: .idle
                ),
            ],
            tabs: tabs, panes: [], layouts: []
        ))
    }

    private struct Probe: View {
        static let size = CGSize(width: 900, height: ChromeMetrics.Strip.height)
        let viewModel: SessionViewModel
        let drag: DragCoordinator

        var body: some View {
            TabStrip(
                theme: .tokyoNight, viewModel: viewModel, workspace: NewTabAffordanceRenderTests.workspace,
                tabs: viewModel.tabsForSelectedWorkspace, selectedTabID: viewModel.selectedTabID,
                protocolVersion: 22, onSelect: { _ in }, previewHoversNewTabAffordance: true
            )
            .environment(drag)
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    private func hostProbe(tabLabels: [String]) async throws -> (window: NSWindow, hosting: NSHostingView<Probe>) {
        let viewModel = SessionViewModel(client: OfflineClient())
        viewModel.update(model: model(tabLabels: tabLabels), connection: .live)
        let toasts = ToastCenter()
        let drag = DragCoordinator(
            toasts: toasts, rearrangeMode: RearrangeMode(),
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in }
        )
        let hosting = NSHostingView(rootView: Probe(viewModel: viewModel, drag: drag))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Probe.size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (window, hosting)
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

    /// Two short tabs leave a wide run past the last one: the preview PNG a
    /// human is asked to look at, and a real, non-transparent pixel proving
    /// the glyph and its outline actually painted rather than nothing at all.
    func testTheAffordanceDrawsATabShapedOutlineWithAPlusInTheStripsFreeRun() async throws {
        let (window, _) = try await hostProbe(tabLabels: ["one", "two"])
        defer { window.close() }

        let image = try snapshot(window)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("tab-strip-new-tab-affordance.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }

        var nonChromePixelCount = 0
        // The affordance sits right past the last tab; sampling a band there
        // (rather than the whole strip) keeps this test from passing on any
        // stray pixel the tabs themselves would already draw.
        for y in 0..<image.pixelsHigh {
            for x in 250..<450 where x < image.pixelsWide {
                if hex(image, x: x, y: y) != chromeHex {
                    nonChromePixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(nonChromePixelCount, 20, "no outline or glyph painted in the strip's free run")
    }

    private var chromeHex: String { Theme.tokyoNight.palette.chromeRoles.chrome.hex }

    private func hex(_ image: NSBitmapImageRep, x: Int, y: Int) -> String {
        guard let data = image.bitmapData else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}
