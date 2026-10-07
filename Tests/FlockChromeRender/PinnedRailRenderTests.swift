import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The rail with a live pin and an empty one under PINNED, over a WORKSPACES
/// row, at rest, with that row dragged into PINNED and with a pin dragged out,
/// in a dark and a light theme. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PinnedRailRenderTests: XCTestCase {
    private static let size = CGSize(width: 280, height: 400)
    private static let scale: CGFloat = 2
    private static let acme = WorkspaceID(rawValue: "w1")
    private static let web = WorkspaceID(rawValue: "w2")
    private static let docs = WorkspaceID(rawValue: "w3")

    private struct Probe: View {
        let theme: Theme
        let viewModel: SessionViewModel
        let drag: DragCoordinator
        let railWidth: RailWidthStore
        let collapse: SectionCollapseStore
        let board: BoardStore
        let toasts: ToastCenter
        let identity: WorkspaceIdentityStore
        let themeStore: ThemeStore
        let defaults: UserDefaults

        var body: some View {
            WorkspaceRail(theme: theme, viewModel: viewModel, onSelect: { _ in })
                .overlay { DragLayer() }
                .environment(themeStore)
                .environment(drag)
                .environment(railWidth)
                .environment(collapse)
                .environment(board)
                .environment(HerdProgressStore(sources: .unanswered))
                .environment(toasts)
                .environment(AllWorkspacesModeStore(userDefaults: defaults))
                .environment(MissionBottomLineStore(userDefaults: defaults))
                .environment(identity)
                .frame(width: PinnedRailRenderTests.size.width, height: PinnedRailRenderTests.size.height, alignment: .topLeading)
        }
    }

    private struct Hosted {
        let window: NSWindow
        let drag: DragCoordinator
        let emptyPin: PinID
    }

    private struct Rendered {
        let image: NSBitmapImageRep
        let drag: DragCoordinator
        let emptyPin: PinID
    }

    func testPinnedSitsAboveWorkspacesWithTheEmptyPinDimmedAndDotless() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let hosted = try await host(theme)
            defer { hosted.window.close() }
            let rendered = Rendered(image: try snapshot(hosted.window), drag: hosted.drag, emptyPin: hosted.emptyPin)
            if let directory {
                try XCTUnwrap(rendered.image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-\(scheme).png"))
            }
            try assertLayout(rendered, theme: theme, scheme: scheme)
        }
    }

    /// A WORKSPACES row carried over PINNED lands among the pins wherever it
    /// is over the section, its heading and side padding included, and the
    /// pins below the gap make room for it.
    func testAWorkspaceDraggedOverPinnedOpensAGapThere() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let hosted = try await host(theme)
            defer { hosted.window.close() }
            let drag = hosted.drag
            let region = try XCTUnwrap(drag.pinnedFrame)
            let pins = drag.pinFrames.map(\.frame)
            XCTAssertEqual(pins.count, 2)
            let docs = try XCTUnwrap(drag.workspaceFrames.first?.frame)
            drag.stripWorkspace = Self.docs

            drag.beginIfIdle(
                .workspace(Self.docs),
                ghost: DragCoordinator.Ghost(title: "docs", symbol: "square.grid.2x2", originSize: docs.size),
                at: CGPoint(x: docs.midX, y: docs.midY)
            )
            drag.move(to: CGPoint(x: region.minX + 2, y: region.minY + 4))
            XCTAssertEqual(drag.target, .pinnedRail(insertIndex: 0), "\(scheme): PINNED's heading, at its leading edge")
            drag.move(to: CGPoint(x: pins[0].midX, y: pins[0].maxY + 1))
            XCTAssertEqual(drag.target, .pinnedRail(insertIndex: 1), "\(scheme): between the two pins")
            XCTAssertEqual(drag.pinDisplacement(at: 0), 0, "\(scheme): the pin above the gap stays")
            XCTAssertEqual(drag.pinDisplacement(at: 1), pins[1].minY - pins[0].minY, "\(scheme): the pin below moves one row")
            XCTAssertEqual(drag.workspaceDisplacement(at: 0), 0, "\(scheme): WORKSPACES does not move")
            let bar = try XCTUnwrap(drag.insertionMark?.bar, "\(scheme): the insertion bar shows in PINNED")
            XCTAssertTrue(pins[0].maxY <= bar.midY && bar.midY <= pins[1].minY, "\(scheme): the bar sits in the gap: \(bar)")

            XCTAssertEqual(drag.pinnedGrowth, pins[1].minY - pins[0].minY, "\(scheme): PINNED makes room for the arriving row")

            for _ in 0..<6 {
                hosted.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(drag.workspaceFrames.first?.frame, docs, "\(scheme): WORKSPACES' resting frames hold while PINNED grows")
            if let directory {
                try XCTUnwrap(try snapshot(hosted.window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-drag-\(scheme).png"))
            }
            drag.release()
        }
    }

    /// With every workspace pinned, WORKSPACES is a heading alone, and a live
    /// pin carried below it is marked there rather than at the top of the
    /// rail; the empty pin cannot leave PINNED at all.
    func testALivePinDraggedIntoAnEmptyWorkspacesIsMarkedBelowItsHeading() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let hosted = try await host(theme, unpinned: [])
            defer { hosted.window.close() }
            let drag = hosted.drag
            XCTAssertTrue(drag.workspaceFrames.isEmpty)
            let region = try XCTUnwrap(drag.pinnedFrame)
            let web = try XCTUnwrap(drag.pinFrames.first { $0.workspace == Self.web })
            drag.stripWorkspace = Self.web
            let below = CGPoint(x: web.frame.midX, y: region.maxY + 40)

            drag.beginIfIdle(
                .pin(hosted.emptyPin),
                ghost: DragCoordinator.Ghost(title: "acme", symbol: "square.grid.2x2", originSize: web.frame.size),
                at: CGPoint(x: web.frame.midX, y: web.frame.maxY + 14)
            )
            drag.move(to: below)
            XCTAssertNil(drag.target, "\(scheme): an empty pin has nowhere to go among the workspaces")
            drag.release()
            try await Task.sleep(for: .seconds(DragVisuals.settleDuration + 0.1))

            drag.beginIfIdle(
                .pin(web.id),
                ghost: DragCoordinator.Ghost(title: "web", symbol: "square.grid.2x2", originSize: web.frame.size),
                at: CGPoint(x: web.frame.midX, y: web.frame.midY)
            )
            drag.move(to: below)
            XCTAssertEqual(drag.target, .workspaceRail(insertIndex: 0), "\(scheme)")
            let bar = try XCTUnwrap(drag.insertionMark?.bar)
            XCTAssertGreaterThan(bar.minY, region.maxY + ChromeMetrics.RailSection.sectionGap, "\(scheme): the bar is below WORKSPACES' heading: \(bar)")
            let pitch = drag.pinFrames[1].frame.minY - drag.pinFrames[0].frame.minY
            XCTAssertEqual(drag.workspacesGrowth, pitch, "\(scheme): WORKSPACES makes room for the pin")

            for _ in 0..<6 {
                hosted.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            if let directory {
                try XCTUnwrap(try snapshot(hosted.window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-dragout-\(scheme).png"))
            }
            drag.release()
        }
    }

    private func assertLayout(_ rendered: Rendered, theme: Theme, scheme: String) throws {
        let roles = theme.palette.chromeRoles
        let drag = rendered.drag
        let region = try XCTUnwrap(drag.pinnedFrame, "\(scheme): PINNED reports its region")
        let pins = drag.pinFrames
        XCTAssertEqual(pins.count, 2, "\(scheme): both pins are rows")
        let firstPin = try XCTUnwrap(pins.first?.frame)
        let empty = try XCTUnwrap(pins.first { $0.id == rendered.emptyPin })
        XCTAssertNil(empty.workspace, "\(scheme): the empty pin carries no workspace")
        let firstWorkspace = try XCTUnwrap(drag.workspaceFrames.first?.frame)

        let headingInk = ChromeMetrics.Rail.headingToFirstRow
        XCTAssertTrue(
            hasInk(rendered.image, rows: region.minY..<(firstPin.minY - headingInk), from: region.minX, roles: roles),
            "\(scheme): PINNED's heading draws above its first row"
        )
        let workspacesHeading = (region.maxY + ChromeMetrics.RailSection.sectionGap)..<(firstWorkspace.minY - headingInk)
        XCTAssertTrue(
            hasInk(rendered.image, rows: workspacesHeading, from: region.minX, roles: roles),
            "\(scheme): WORKSPACES' heading draws below PINNED and above its own row"
        )
        XCTAssertLessThan(region.maxY, workspacesHeading.lowerBound, "\(scheme): PINNED sits above WORKSPACES")

        let row = empty.frame
        let ground = sample(rendered.image, CGPoint(x: row.maxX - 4, y: row.midY))
        XCTAssertEqual(ground, roles.chrome, "\(scheme): the empty row draws no fill")
        let dotMinX = row.minX + ChromeMetrics.WorkspaceRow.horizontalPadding
        let dot = CGRect(
            x: dotMinX, y: row.midY - ChromeMetrics.WorkspaceRow.statusDot / 2,
            width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot
        )
        XCTAssertNil(strongestInk(rendered.image, in: dot, ground: roles.chrome), "\(scheme): the empty row's dot slot is blank")

        let nameMinX = dotMinX + ChromeMetrics.WorkspaceRow.statusDot + ChromeMetrics.WorkspaceRow.spacing
            + ChromeMetrics.WorkspaceRow.mark + ChromeMetrics.WorkspaceRow.spacing
        let name = CGRect(
            x: nameMinX, y: row.minY + ChromeMetrics.WorkspaceRow.verticalPadding,
            width: 24, height: ChromeMetrics.WorkspaceRow.contentHeight
        )
        let ink = try XCTUnwrap(strongestInk(rendered.image, in: name, ground: roles.chrome), "\(scheme): the empty pin draws its name")
        XCTAssertLessThan(
            distance(ink, roles.textLabel), distance(ink, roles.textStrong),
            "\(scheme): the empty pin's name is textLabel (\(roles.textLabel.hex)), not textStrong (\(roles.textStrong.hex)); drew \(ink.hex)"
        )
    }

    private func host(_ theme: Theme, unpinned: [WorkspaceID] = [PinnedRailRenderTests.docs]) async throws -> Hosted {
        let suite = "PinnedRailRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        viewModel.update(model: model([Self.acme, Self.web] + unpinned), connection: .live)
        viewModel.pin(workspace: Self.web)
        viewModel.pin(workspace: Self.acme)
        viewModel.update(model: model([Self.web] + unpinned), connection: .live)
        let emptyPin = try XCTUnwrap(viewModel.pins.pins.first { $0.workspace == nil }?.id, "acme's pin is empty")

        let toasts = ToastCenter()
        let drag = DragCoordinator(
            toasts: toasts, rearrangeMode: RearrangeMode(),
            commit: { _, _ in .noOp },
            reveal: { _ in }
        )
        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let railWidth = RailWidthStore(userDefaults: defaults)
        railWidth.released(at: Self.size.width - ChromeMetrics.ruleWidth)
        let probe = Probe(
            theme: theme, viewModel: viewModel, drag: drag, railWidth: railWidth,
            collapse: SectionCollapseStore(userDefaults: defaults),
            board: BoardStore(sources: .unconfigured, userDefaults: defaults),
            toasts: toasts, identity: identity, themeStore: themeStore, defaults: defaults
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: probe)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return Hosted(window: window, drag: drag, emptyPin: emptyPin)
    }

    private func model(_ ids: [WorkspaceID]) -> SessionModel {
        let labels = [Self.acme: "acme", Self.web: "web", Self.docs: "docs"]
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: Self.docs, focusedTabID: nil, focusedPaneID: nil,
            workspaces: ids.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: labels[id] ?? id.rawValue, number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: .idle
                )
            },
            tabs: ids.map { id in
                TabRecord(
                    tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "first",
                    number: 1, paneCount: 1, agentStatus: .idle
                )
            },
            panes: [],
            layouts: []
        ))
    }

    /// Whether any pixel along `rows`, from `minX` across the heading's
    /// width, is something other than the rail's ground.
    private func hasInk(_ image: NSBitmapImageRep, rows: Range<CGFloat>, from minX: CGFloat, roles: ChromeRoles) -> Bool {
        guard !rows.isEmpty else { return false }
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 0.5) {
            for x in stride(from: minX, to: minX + 80, by: 0.5) where sample(image, CGPoint(x: x, y: y)) != roles.chrome {
                return true
            }
        }
        return false
    }

    /// The pixel in `box` farthest from `ground`: a glyph's solid core, not
    /// its antialiased edge. nil when the whole box is ground.
    private func strongestInk(_ image: NSBitmapImageRep, in box: CGRect, ground: RGB) -> RGB? {
        var best: (RGB, Double)?
        for y in stride(from: box.minY, to: box.maxY, by: 0.5) {
            for x in stride(from: box.minX, to: box.maxX, by: 0.5) {
                guard let pixel = sample(image, CGPoint(x: x, y: y)) else { continue }
                let away = distance(pixel, ground)
                if away > (best?.1 ?? 0) { best = (pixel, away) }
            }
        }
        return best?.0
    }

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.red - b.red), dg = Double(a.green - b.green), db = Double(a.blue - b.blue)
        return (dr * dr + dg * dg + db * db).squareRoot()
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

    private func sample(_ image: NSBitmapImageRep, _ point: CGPoint) -> RGB? {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return RGB(Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}
