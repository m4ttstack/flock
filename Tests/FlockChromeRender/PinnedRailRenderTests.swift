import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The rail with a live pin and an empty one under PINNED, over a WORKSPACES
/// row, at rest, with that row dragged into PINNED and with a pin dragged out,
/// over BOARD with nothing left unpinned, and the pins in ⌃Tab's panel, in a
/// dark and a light theme. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PinnedRailRenderTests: XCTestCase {
    private static let size = CGSize(width: 280, height: 400)
    private static let scale: CGFloat = 2
    private static let acme = WorkspaceID(rawValue: "w1")
    private static let web = WorkspaceID(rawValue: "w2")
    private static let docs = WorkspaceID(rawValue: "w3")
    private static let api = WorkspaceID(rawValue: "w4")
    private static let reviews = WorkspaceID(rawValue: "w5")
    private static let doctors = WorkspaceID(rawValue: "w6")
    /// How far a filled symbol's core may sit from its colour once
    /// rasterized: a channel step or two.
    private static let glyphCoreTolerance: Double = 3
    /// Text stems are thinner than a pixel pair at this size, so their
    /// darkest pixel still carries a little ground. Every role pair the rail
    /// uses sits ten times further apart than this.
    private static let textCoreTolerance: Double = 12

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

    /// With every workspace pinned, WORKSPACES draws nothing at rest. Its
    /// heading shows for a live pin's drag alone, and the pin carried below it
    /// is marked there rather than at the top of the rail; the empty pin
    /// cannot leave PINNED at all.
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
            let roles = theme.palette.chromeRoles
            let headingBand = (region.maxY + ChromeMetrics.RailSection.sectionGap)..<(region.maxY + 40)
            XCTAssertNil(drag.workspacesHeading, "\(scheme): no WORKSPACES heading at rest")
            let resting = try snapshot(hosted.window)
            if let directory {
                try XCTUnwrap(resting.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-allpinned-\(scheme).png"))
            }
            XCTAssertFalse(
                hasInk(resting, rows: headingBand, from: region.minX + ChromeMetrics.Rail.horizontalPadding, roles: roles),
                "\(scheme): nothing drawn where the heading would be"
            )

            drag.beginIfIdle(
                .pin(hosted.emptyPin),
                ghost: DragCoordinator.Ghost(title: "acme", symbol: "square.grid.2x2", originSize: web.frame.size),
                at: CGPoint(x: web.frame.midX, y: web.frame.maxY + 14)
            )
            try await settle(hosted.window)
            XCTAssertNil(drag.workspacesHeading, "\(scheme): an empty pin's drag shows no WORKSPACES heading")
            drag.move(to: below)
            XCTAssertNil(drag.target, "\(scheme): an empty pin has nowhere to go among the workspaces")
            let refused = try XCTUnwrap(drag.refusedZone, "\(scheme): the rail below PINNED says the drop is refused")
            XCTAssertGreaterThan(refused.minY, region.maxY, "\(scheme): the refusal sits below PINNED")
            try await settle(hosted.window)
            if let directory {
                try XCTUnwrap(try snapshot(hosted.window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-refused-\(scheme).png"))
            }
            drag.move(to: CGPoint(x: web.frame.midX, y: web.frame.midY))
            XCTAssertNil(drag.refusedZone, "\(scheme): over PINNED nothing is refused")
            drag.move(to: below)
            drag.release()
            XCTAssertNil(drag.refusedZone, "\(scheme): the refusal goes with the drag")
            try await Task.sleep(for: .seconds(DragVisuals.settleDuration + 0.1))

            drag.beginIfIdle(
                .pin(web.id),
                ghost: DragCoordinator.Ghost(title: "web", symbol: "square.grid.2x2", originSize: web.frame.size),
                at: CGPoint(x: web.frame.midX, y: web.frame.midY)
            )
            try await settle(hosted.window)
            XCTAssertNotNil(drag.workspacesHeading, "\(scheme): a live pin's drag shows the WORKSPACES heading")
            XCTAssertTrue(
                hasInk(try snapshot(hosted.window), rows: headingBand, from: region.minX + ChromeMetrics.Rail.horizontalPadding, roles: roles),
                "\(scheme): the heading draws below PINNED"
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
            try await Task.sleep(for: .milliseconds(60))
            let landing = try XCTUnwrap(drag.ghostTopLeft, "\(scheme): the ghost is still settling")
            XCTAssertGreaterThan(landing.y, bar.minY - web.frame.height, "\(scheme): the ghost settles where the bar was, not at the top of PINNED")
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
        let dimmed = Self.emptyPinInk(roles)
        let ink = try XCTUnwrap(strongestInk(rendered.image, in: name, ground: roles.chrome), "\(scheme): the empty pin draws its name")
        XCTAssertLessThanOrEqual(
            distance(ink, dimmed), Self.textCoreTolerance,
            "\(scheme): the empty pin's name is dimmed textLabel (\(dimmed.hex)); its core drew \(ink.hex)"
        )
        let mark = CGRect(
            x: dotMinX + ChromeMetrics.WorkspaceRow.statusDot + ChromeMetrics.WorkspaceRow.spacing,
            y: row.midY - ChromeMetrics.WorkspaceRow.mark / 2,
            width: ChromeMetrics.WorkspaceRow.mark, height: ChromeMetrics.WorkspaceRow.mark
        )
        let symbol = try XCTUnwrap(strongestInk(rendered.image, in: mark, ground: roles.chrome), "\(scheme): the empty pin draws its symbol")
        XCTAssertLessThanOrEqual(
            distance(symbol, dimmed), Self.glyphCoreTolerance,
            "\(scheme): the empty pin's symbol is dimmed textLabel (\(dimmed.hex)); its core drew \(symbol.hex)"
        )
    }

    /// textLabel at the empty pin's opacity over the ground it sits on, the
    /// rail's chrome unless given.
    private static func emptyPinInk(_ roles: ChromeRoles, over ground: RGB? = nil) -> RGB {
        let under = ground ?? roles.chrome
        let alpha = ChromeMetrics.WorkspaceRow.emptyPinOpacity
        func blend(_ over: Int, _ under: Int) -> Int { Int((Double(over) * alpha + Double(under) * (1 - alpha)).rounded()) }
        return RGB(
            blend(roles.textLabel.red, under.red), blend(roles.textLabel.green, under.green),
            blend(roles.textLabel.blue, under.blue)
        )
    }

    /// With every workspace pinned, BOARD follows PINNED directly, a section
    /// gap below it, the way WORKSPACES' heading would.
    func testWithEveryWorkspacePinnedBoardFollowsPinned() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let session = try session(
                workspaces: [Self.acme, Self.web, Self.reviews, Self.doctors], pinned: [Self.web, Self.acme], closed: [Self.acme]
            )
            let (window, drag) = try await mount(theme, session: session, boardSources: .canned(logo: BoardFixture.logo))
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("pinned-rail-board-\(scheme).png"))
            }
            XCTAssertTrue(drag.workspaceFrames.isEmpty, "\(scheme): no WORKSPACES rows")
            XCTAssertNil(drag.workspacesHeading, "\(scheme): no WORKSPACES heading")
            let region = try XCTUnwrap(drag.pinnedFrame)
            let roles = theme.palette.chromeRoles
            let gap = region.maxY..<(region.maxY + ChromeMetrics.RailSection.sectionGap)
            XCTAssertFalse(hasInk(image, rows: gap, from: region.minX, roles: roles), "\(scheme): a clear section gap under PINNED")
            XCTAssertTrue(
                hasInk(image, rows: gap.upperBound..<(gap.upperBound + ChromeMetrics.RailSection.headerMark), from: region.minX, roles: roles),
                "\(scheme): BOARD's header sits right under the gap"
            )
        }
    }

    /// ⌃Tab's panel over a live workspace, a live pin and an empty one: the
    /// empty pin's row is the rail's, with no dot, its name dimmed and no
    /// count, and the highlight is on the row letting go opens.
    func testTheSwitcherDrawsAnEmptyPinAsTheRailDoes() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let size = CGSize(width: 480, height: 360)
        typealias Metrics = ChromeMetrics.Palette
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let session = try session(unpinned: [Self.docs])
            let viewModel = session.viewModel
            let emptyPin = try XCTUnwrap(viewModel.pins.pins.first { $0.workspace == nil })
            let switcher = WorkspaceSwitcher(userDefaults: session.defaults)
            let view = SwitcherView(
                theme: theme, switcher: switcher, trigger: .control, accessibilityPrefix: "flock.switcher", heading: "Workspaces",
                row: { SwitcherOverlay.workspaceRow($0, viewModel: viewModel) },
                candidates: { SwitcherOverlay.workspaceCandidates(viewModel: viewModel) },
                current: { viewModel.selectedWorkspaceID },
                blocked: { false },
                go: { _ in }
            )
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(theme.chrome))
            defer { window.close() }
            try await settle(window)
            view.begin(reverse: false)
            switcher.show(session: switcher.session)
            try await settle(window)
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("switcher-pins-\(scheme).png"))
            }

            XCTAssertEqual(switcher.order, [Self.docs, Self.web, emptyPin.switcherID], "\(scheme): current, the live pin, the empty pin")
            XCTAssertEqual(switcher.selected, Self.web, "\(scheme)")
            let roles = theme.palette.chromeRoles
            let top = ChromeMetrics.Switcher.top(inTabAreaHeight: size.height, rowCount: 3)
            let boxX = (size.width - ChromeMetrics.Switcher.width) / 2
            let rowY = { (index: Int) in
                top + ChromeMetrics.Switcher.headerHeight + ChromeMetrics.ruleWidth + Metrics.listPadding + CGFloat(index) * (Metrics.rowHeight + 1)
            }
            let dotX = boxX + Metrics.listPadding + Metrics.rowPadding + 2
            let dot = { (index: Int) in
                CGRect(
                    x: dotX, y: rowY(index) + (Metrics.rowHeight - ChromeMetrics.WorkspaceRow.statusDot) / 2,
                    width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot
                )
            }
            let count = { (index: Int) in
                CGRect(x: boxX + ChromeMetrics.Switcher.width - Metrics.listPadding - Metrics.rowPadding - 14, y: rowY(index) + 8, width: 12, height: Metrics.rowHeight - 16)
            }
            let name = { (index: Int) in
                CGRect(x: dotX + ChromeMetrics.WorkspaceRow.statusDot + Metrics.rowGap, y: rowY(index) + 8, width: 24, height: Metrics.rowHeight - 16)
            }
            // The box's own ground, read off a blank stretch of the empty row.
            let ground = try XCTUnwrap(sample(image, CGPoint(x: boxX + ChromeMetrics.Switcher.width * 0.6, y: rowY(2) + Metrics.rowHeight / 2)))
            XCTAssertNotNil(strongestInk(image, in: dot(0), ground: ground), "\(scheme): a live workspace draws its dot")
            XCTAssertNotNil(strongestInk(image, in: count(0), ground: ground), "\(scheme): a live workspace draws its count")
            XCTAssertNil(strongestInk(image, in: dot(2), ground: ground, beyond: 3), "\(scheme): the empty pin's dot slot is blank")
            XCTAssertNil(strongestInk(image, in: count(2), ground: ground, beyond: 3), "\(scheme): the empty pin draws no count")
            let live = try XCTUnwrap(strongestInk(image, in: name(0), ground: ground))
            XCTAssertLessThanOrEqual(distance(live, roles.textStrong), Self.textCoreTolerance, "\(scheme): a live name is textStrong; drew \(live.hex)")
            let dimmed = Self.emptyPinInk(roles, over: ground)
            let empty = try XCTUnwrap(strongestInk(image, in: name(2), ground: ground), "\(scheme): the empty pin draws its name")
            XCTAssertLessThanOrEqual(
                distance(empty, dimmed), Self.textCoreTolerance, "\(scheme): the empty pin's name is dimmed textLabel (\(dimmed.hex)); drew \(empty.hex)"
            )
            let selection = try XCTUnwrap(sample(image, CGPoint(x: boxX + ChromeMetrics.Switcher.width - 30, y: rowY(1) + 4)))
            XCTAssertEqual(selection, roles.selection, "\(scheme): the highlight is on the live pin, the row letting go opens")
        }
    }

    private struct Session {
        let viewModel: SessionViewModel
        let identity: WorkspaceIdentityStore
        let defaults: UserDefaults
    }

    /// `web` pinned and live, then `acme` pinned and closed, so its pin is
    /// empty.
    private func session(unpinned: [WorkspaceID]) throws -> Session {
        try session(workspaces: [Self.acme, Self.web] + unpinned, pinned: [Self.web, Self.acme], closed: [Self.acme])
    }

    private func session(workspaces: [WorkspaceID], pinned: [WorkspaceID], closed: [WorkspaceID]) throws -> Session {
        let suite = "PinnedRailRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        viewModel.update(model: model(workspaces), connection: .live)
        for workspace in pinned {
            viewModel.pin(workspace: workspace)
        }
        if !closed.isEmpty {
            viewModel.update(model: model(workspaces.filter { !closed.contains($0) }), connection: .live)
        }
        return Session(viewModel: viewModel, identity: identity, defaults: defaults)
    }

    private func host(_ theme: Theme, unpinned: [WorkspaceID] = [PinnedRailRenderTests.docs]) async throws -> Hosted {
        let session = try session(unpinned: unpinned)
        let emptyPin = try XCTUnwrap(session.viewModel.pins.pins.first { $0.workspace == nil }?.id, "acme's pin is empty")
        session.identity.setOverride("cylinder.fill", for: "pin:\(emptyPin.rawValue)")
        let (window, drag) = try await mount(theme, session: session)
        return Hosted(window: window, drag: drag, emptyPin: emptyPin)
    }

    /// Drops commit through the view model, as the app's do.
    private func mount(
        _ theme: Theme, session: Session, boardSources: BoardSources = .unconfigured
    ) async throws -> (NSWindow, DragCoordinator) {
        let viewModel = session.viewModel
        let defaults = session.defaults
        let board = BoardStore(sources: boardSources, userDefaults: defaults)
        await board.refresh()
        let toasts = ToastCenter()
        let drag = DragCoordinator(
            toasts: toasts, rearrangeMode: RearrangeMode(),
            commit: { subject, target in await viewModel.perform(subject: subject, target: target) },
            reveal: { _ in }
        )
        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let railWidth = RailWidthStore(userDefaults: defaults)
        railWidth.released(at: Self.size.width - ChromeMetrics.ruleWidth)
        let probe = Probe(
            theme: theme, viewModel: viewModel, drag: drag, railWidth: railWidth,
            collapse: SectionCollapseStore(userDefaults: defaults),
            board: board,
            toasts: toasts, identity: session.identity, themeStore: themeStore, defaults: defaults
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: probe)
        try await settle(window)
        return (window, drag)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// What a rail mounted fresh on the same session reports, which is where
    /// the rows are actually laid out.
    private func assertFramesMatchAFreshRail(_ drag: DragCoordinator, session: Session, _ message: String) async throws {
        let (window, fresh) = try await mount(.tokyoNight, session: session)
        defer { window.close() }
        XCTAssertEqual(drag.workspaceFrames, fresh.workspaceFrames, "\(message): WORKSPACES rows")
        XCTAssertEqual(drag.pinFrames, fresh.pinFrames, "\(message): PINNED rows")
        XCTAssertEqual(drag.pinnedFrame, fresh.pinnedFrame, "\(message): PINNED's region")
        XCTAssertEqual(drag.workspacesHeading, fresh.workspacesHeading, "\(message): WORKSPACES' heading")
    }

    /// Committed drops move rows between the lists; every frame the
    /// coordinator holds afterwards is where its row really is, so the next
    /// drag hit-tests the rail as drawn. In the app a drop's commit can land
    /// before the rail lays out the drag's end, so each drop here applies its
    /// change in the same turn as the release, and the commit that follows
    /// finds it already made.
    func testRailFramesMatchTheRowsAfterAWorkspaceIsPinnedAndUnpinnedByDragging() async throws {
        ChromeType.install()
        let session = try session(
            workspaces: [Self.acme, Self.web, Self.api, Self.docs], pinned: [Self.web, Self.api], closed: []
        )
        let (window, drag) = try await mount(.tokyoNight, session: session)
        defer { window.close() }
        drag.stripWorkspace = Self.docs

        let api = try XCTUnwrap(drag.pinFrames.last?.frame)
        let docs = try XCTUnwrap(drag.workspaceFrames.last?.frame)
        let lastPin = CGPoint(x: api.midX, y: api.midY + 4)
        drag.beginIfIdle(
            .workspace(Self.docs),
            ghost: DragCoordinator.Ghost(title: "docs", symbol: "square.grid.2x2", originSize: docs.size),
            at: CGPoint(x: docs.midX, y: docs.midY)
        )
        drag.move(to: lastPin)
        XCTAssertEqual(drag.target, .pinnedRail(insertIndex: 2))
        try await settle(window)
        drag.release(at: lastPin)
        session.viewModel.pin(workspace: Self.docs, at: 2)
        try await Task.sleep(for: .seconds(DragVisuals.settleDuration + 0.1))
        try await settle(window)
        XCTAssertNotNil(session.viewModel.pins.pin(linkedTo: Self.docs), "docs is pinned")
        try await assertFramesMatchAFreshRail(drag, session: session, "after docs is pinned")

        let webPin = try XCTUnwrap(session.viewModel.pins.pin(linkedTo: Self.web)?.id)
        let webRow = try XCTUnwrap(drag.pinFrames.first { $0.id == webPin }?.frame)
        let acme = try XCTUnwrap(drag.workspaceFrames.first?.frame)
        let below = CGPoint(x: acme.midX, y: acme.maxY + 4)
        drag.beginIfIdle(
            .pin(webPin),
            ghost: DragCoordinator.Ghost(title: "web", symbol: "square.grid.2x2", originSize: webRow.size),
            at: CGPoint(x: webRow.midX, y: webRow.midY)
        )
        drag.move(to: below)
        XCTAssertEqual(drag.target, .workspaceRail(insertIndex: 1))
        try await settle(window)
        drag.release(at: below)
        session.viewModel.unpin(webPin)
        try await Task.sleep(for: .seconds(DragVisuals.settleDuration + 0.1))
        try await settle(window)
        XCTAssertNil(session.viewModel.pins.pin(linkedTo: Self.web), "web is unpinned")
        try await assertFramesMatchAFreshRail(drag, session: session, "after web is unpinned")
    }

    private func model(_ ids: [WorkspaceID]) -> SessionModel {
        let labels = [
            Self.acme: "acme", Self.web: "web", Self.docs: "docs", Self.api: "api",
            Self.reviews: BoardFixture.names.reviews, Self.doctors: BoardFixture.names.doctors,
        ]
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
    /// `beyond` ignores pixels that close to `ground`, for a ground that is
    /// itself a channel step uneven.
    private func strongestInk(_ image: NSBitmapImageRep, in box: CGRect, ground: RGB, beyond: Double = 0) -> RGB? {
        var best: (RGB, Double)?
        for y in stride(from: box.minY, to: box.maxY, by: 0.5) {
            for x in stride(from: box.minX, to: box.maxX, by: 0.5) {
                guard let pixel = sample(image, CGPoint(x: x, y: y)) else { continue }
                let away = distance(pixel, ground)
                if away > max(best?.1 ?? 0, beyond) { best = (pixel, away) }
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
