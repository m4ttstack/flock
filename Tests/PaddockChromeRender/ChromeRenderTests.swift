import AppKit
import PaddockCore
import SwiftUI
import XCTest

/// Renders the real `MainWindow` offscreen from fixture data, with no app host
/// and no herdr connection. Pane bodies are ground-only surfaces, since
/// terminal content is not part of the chrome. PNGs are written only when
/// `PADDOCK_CHROME_RENDER_DIR` is set; the pixel and window assertions always
/// run.
@MainActor
final class ChromeRenderTests: XCTestCase {
    static let defaultsSuite = "dev.mattstack.paddock.chrome-render"
    private static let windowSize = CGSize(width: 900, height: 560)
    private static let themeIDs = [
        "tokyo-night", "dracula",
        "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
        "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
    ]

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.defaultsSuite)
        super.tearDown()
    }

    func testEveryChromeRolePaintsItsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in Self.themeIDs {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            assertSamples(image, theme: theme)
            window.close()
        }
    }

    /// A face that failed to register resolves to the system font with no
    /// error, so only a lookup by name shows the chrome is really in Inter.
    func testChromeFacesResolveToInterWithDistinctWeights() throws {
        ChromeType.install()
        var weights: [CGFloat] = []
        for weight in ChromeType.Weight.allCases {
            let font = try XCTUnwrap(NSFont(name: weight.postScriptName, size: 14), weight.postScriptName)
            XCTAssertEqual(font.familyName, "Inter", weight.postScriptName)
            let traits = try XCTUnwrap(CTFontCopyTraits(font) as? [CFString: Any])
            weights.append(try XCTUnwrap(traits[kCTFontWeightTrait] as? CGFloat, weight.postScriptName))
        }
        XCTAssertEqual(weights, weights.sorted())
        XCTAssertEqual(Set(weights).count, weights.count, "\(weights)")
    }

    func testWindowButtonsCenterOnTheTitleBarAndStayThereAfterAResize() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        assertButtonsCentered(in: window)

        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(window)
        assertButtonsCentered(in: window)
        window.close()
    }

    /// AppKit rebuilds the standard buttons on a style mask change. The next
    /// pass must move its frame observers onto the new buttons, or AppKit
    /// laying one out again later leaves it off center until some window event.
    func testReplacedWindowButtonsAreObservedAndKeptCentered() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let before = WindowButtonCentering.buttons(of: window)

        window.styleMask.remove(.titled)
        window.styleMask.insert(.titled)
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(window)
        let after = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(zip(before, after).contains { $0 === $1 }, "the style mask change kept the same buttons, so nothing was replaced")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + 6))
        assertButtonsCentered(in: window)
        window.close()
    }

    /// The system title bar is taller than the chrome's, so the top of the tab
    /// strip lies inside it. A press there must stay with the strip: some view
    /// of ours at that point opts out of moving the window. The chrome title
    /// bar drags and double-clicks through `TitleBarMouseView`, so every point
    /// on it must reach that view.
    func testTabStripTopInsideTheSystemTitleBarDoesNotMoveTheWindow() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let systemTitleBarHeight = window.frame.height - window.contentLayoutRect.maxY
        let stripTop = ChromeMetrics.TitleBar.height
        XCTAssertGreaterThan(systemTitleBarHeight, stripTop + 1, "the system title bar no longer reaches the tab strip, so this test exercises nothing")

        let stripTopEdge = CGPoint(x: 260, y: stripTop + 1)
        XCTAssertTrue(contentViews(at: stripTopEdge, in: window).contains { !$0.mouseDownCanMoveWindow })
        for titlePoint in [CGPoint(x: 450, y: 10), CGPoint(x: 250, y: 10), CGPoint(x: 800, y: 3)] {
            XCTAssertTrue(contentViews(at: titlePoint, in: window).contains { $0 is TitleBarMouseView }, "\(titlePoint)")
        }
        window.close()
    }

    /// The All Workspaces grid from fixture layouts: at rest with a pane's
    /// hover card open, then with the nine-tab card expanded. PNGs are
    /// written only when `PADDOCK_GRID_RENDER_DIR` is set; the samples and
    /// the no-attach check always run.
    func testAllWorkspacesGridRendersFromLayoutsWithoutAttachingAPane() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let shownByTheCanvas = Set(model.panes.keys.filter { harness.viewModel.ghosttySurface(for: $0) != nil })
        XCTAssertLessThan(shownByTheCanvas.count, model.panes.count, "every pane is on the canvas, so the no-attach check below proves nothing")
        harness.drag.toggleGrid()
        await settle(window)

        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let panes = MiniPaneLayout.paneArea(in: thumbnail, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        let boxes = MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: panes.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        )
        let claude = try XCTUnwrap(boxes.first { $0.pane == GridFixture.claudePane })
        harness.drag.gridHoverMoved(pane: claude.pane, pointer: CGPoint(x: panes.minX + claude.frame.midX, y: panes.minY + claude.frame.midY))
        harness.drag.gridHoverIntentElapsed(pane: claude.pane)
        await settle(window)
        let rest = try snapshot(window)
        if let directory {
            try XCTUnwrap(rest.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-hover.png"))
        }
        for pane in model.panes.keys where !shownByTheCanvas.contains(pane) {
            XCTAssertNil(harness.viewModel.ghosttySurface(for: pane), "the grid attached \(pane.rawValue)")
        }
        assertGridSamples(rest, theme: .tokyoNight)

        harness.drag.gridHoverEnded(pane: claude.pane)
        harness.drag.toggleGridCard(GridFixture.repoTools)
        await settle(window)
        let expanded = try snapshot(window)
        if let directory {
            try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-expanded.png"))
        }
        assertGridSamples(expanded, theme: .tokyoNight)
        window.close()
    }

    /// The strip's overflow hint, which no other render reaches: the fixture
    /// window's four tabs never overflow. repo-tools has nine, so the strip
    /// scrolls and each end of its run hides tabs on exactly one side.
    func testAnOverflowingStripFadesOnlyTheEdgeThatHidesTabs() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)

        XCTAssertEqual(harness.drag.stripEdgeFade, TabStripScrollGeometry.EdgeFade(leading: false, trailing: true))
        let start = try snapshot(window)
        if let directory {
            try XCTUnwrap(start.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("strip-fade-start.png"))
        }

        // Past the end of the run; the scroll view clamps it to the maximum.
        harness.drag.stripScroller?(10_000)
        await settle(window)
        XCTAssertEqual(harness.drag.stripEdgeFade, TabStripScrollGeometry.EdgeFade(leading: true, trailing: false))
        let end = try snapshot(window)
        if let directory {
            try XCTUnwrap(end.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("strip-fade-end.png"))
        }

        // The strip is the only thing that differs between the two: the rail,
        // the canvas and the title bar are untouched by a strip scroll.
        XCTAssertEqual(hex(start, CGPoint(x: 100, y: 74)), hex(end, CGPoint(x: 100, y: 74)), "the rail")
        XCTAssertEqual(hex(start, CGPoint(x: 700, y: 400)), hex(end, CGPoint(x: 700, y: 400)), "the canvas")
        XCTAssertNotEqual(hex(start, CGPoint(x: 210, y: 40)), hex(end, CGPoint(x: 210, y: 40)), "the strip's leading edge")
        window.close()
    }

    /// A pane dragged out of a mini pane, first over another workspace's
    /// thumbnail and then over a third workspace's card where no thumbnail
    /// sits. Both renders carry the ghost, the drop wash and the targeted
    /// card's accent outline.
    func testAGridDragWashesTheThumbnailThenTheCardItIsOver() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
        let source = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let sourcePanes = MiniPaneLayout.paneArea(in: source, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        let claude = try XCTUnwrap(MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: sourcePanes.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        ).first { $0.pane == GridFixture.claudePane })
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(
                title: "claude", symbol: "macwindow", originSize: claude.frame.size, isCompact: true
            ),
            at: CGPoint(x: sourcePanes.minX + claude.frame.midX, y: sourcePanes.minY + claude.frame.midY)
        )

        // The tab's handle strip, which is the one part of a thumbnail that
        // still means the whole tab: a point over a mini pane names that pane.
        let target = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.migrationTab }?.frame)
        harness.drag.move(to: CGPoint(x: target.midX, y: target.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(harness.drag.target, .tabThumbnail(GridFixture.migrationTab))
        await settle(window)
        let overThumbnail = try snapshot(window)
        if let directory {
            try XCTUnwrap(overThumbnail.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-thumbnail.png"))
        }
        assertGridSamples(overThumbnail, theme: .tokyoNight)

        // The card's header row: inside the card, and no thumbnail or tile
        // covers it, which is what makes it the card's own empty space.
        let card = try XCTUnwrap(grid.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        harness.drag.move(to: CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        ))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps))
        await settle(window)
        let overCard = try snapshot(window)
        if let directory {
            try XCTUnwrap(overCard.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-card.png"))
        }
        assertGridSamples(overCard, theme: .tokyoNight)
        window.close()
    }

    /// A tab dragged over its own card: the card opens the slot the drop will
    /// land it in, on the strip's rule, and the cells it passes come back the
    /// other way. Read through the focus bar, which is drawn in one strip
    /// only: where it sits is where that tab is.
    func testACardOpensTheSlotATabReorderWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.repoTools })
        XCTAssertEqual(card.tabs.map(\.id.rawValue), ["w1:t1", "w1:t2", "w1:t3"], "the three tabs a resting card draws")
        let first = card.tabs[0].frame
        let second = card.tabs[1].frame
        let cardFrame = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame)

        let atRest = try snapshot(window)
        XCTAssertEqual(hex(atRest, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.accent.hex, "the focused tab's own bar")
        XCTAssertEqual(hex(atRest, Self.focusBarPoint(of: second)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex, "and no other")

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: first.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: first.midX, y: first.minY + ChromeMetrics.Grid.tabStripHeight / 2),
            home: DragCoordinator.DragHome(atStart: first, item: .tab(GridFixture.agentsTab), boxInItem: CGRect(origin: .zero, size: first.size))
        )
        harness.drag.move(to: CGPoint(x: second.midX + 10, y: second.midY))
        XCTAssertEqual(harness.drag.target, .tabStrip(workspace: GridFixture.repoTools, insertIndex: 2))
        await settle(window)

        let slide = second.minX - first.minX
        let displacements = harness.drag.gridTabDisplacements(inCardFor: GridFixture.repoTools)
        XCTAssertEqual(displacements[GridFixture.agentsTab], CGSize(width: slide, height: 0))
        XCTAssertEqual(displacements[TabID(rawValue: "w1:t2")], CGSize(width: -slide, height: 0))
        XCTAssertEqual(displacements[TabID(rawValue: "w1:t3")], .zero, "a cell the drag never passed")
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame, cardFrame,
            "a reorder opens no row: the card is the shape it was"
        )

        let mid = try snapshot(window)
        XCTAssertEqual(
            hex(mid, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the first slot still holds the focused tab, so nothing slid"
        )
        XCTAssertNotEqual(
            hex(mid, Self.focusBarPoint(of: second)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the dragged tab did not slide into the slot it is about to take"
        )
        if let directory {
            try XCTUnwrap(mid.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-reorder.png"))
        }
        window.close()
    }

    /// A pane dropped in a card's empty space makes a tab there wherever the
    /// pane came from, and the card's own tabs stay where they are in all
    /// three ways it can arrive: from another workspace, from a multi-pane
    /// tab of this card, and from the only pane of a tab of this card, which
    /// the same drop takes away. The placeholder takes the free slot after
    /// them every time, so a card always keeps the tab the drag came from to
    /// drop back onto.
    func testACardPreviewsTheNewTabWhereverThePaneCameFrom() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        // Three tabs, none hidden, so every slot the card draws is a real one.
        let cells = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.herdr }?.tabs)
        XCTAssertEqual(cells.map(\.id), [GridFixture.srcTab, GridFixture.buildTab, GridFixture.issuesTab])
        let slots = cells.map(\.frame)

        // From another workspace: the card keeps its three tabs and the
        // created one takes the next slot.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.claudePane, harness: harness, window: window,
            follows: slots[2], render: nil, directory: nil
        )
        // From a multi-pane tab of this very card: the same slot, since the
        // tab the pane leaves keeps its other panes.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.buildPane, harness: harness, window: window,
            follows: slots[2], render: nil, directory: nil
        )
        // From the only pane of a tab of this card: that tab goes with the
        // drop, and it STAYS DRAWN in its own slot until then, so the
        // placeholder takes the same free slot as the other two. The created
        // tab lands one cell earlier though, in the slot the emptied tab
        // vacates, which is the rect the ghost and the flash have to use.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.srcPane, harness: harness, window: window,
            lands: slots[2], render: "grid-drag-new-tab-same-workspace.png", directory: directory
        )
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.herdr }?.tabs.map(\.frame), slots,
            "a card's own tabs moved for a drop it was only being hovered with"
        )
        // The smallest shape of the same case: a card of ONE tab, whose only
        // pane is the one being dragged. The tab it came from is still there
        // to drop back onto, and the placeholder stands beside it.
        let only = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.glanceTab }?.frame)
        try await assertNewTabSlot(
            of: GridFixture.glance, dragging: GridFixture.glancePane, harness: harness, window: window,
            lands: only, render: nil, directory: nil
        )
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.glanceTab }?.frame, only,
            "the one-tab card lost the very tab the drag came from"
        )
        window.close()
    }

    /// Drives one pane drag onto a card's empty space and pins where the
    /// placeholder stands: either in the slot after `follows`, or exactly on
    /// `lands`.
    private func assertNewTabSlot(
        of workspace: WorkspaceID, dragging pane: PaneID, harness: Harness, window: NSWindow,
        follows previous: CGRect? = nil, lands: CGRect? = nil, render: String?, directory: String?
    ) async throws {
        harness.drag.beginIfIdle(
            .pane(pane), ghost: DragCoordinator.Ghost(title: "pane", symbol: "macwindow", originSize: CGSize(width: 40, height: 40), isCompact: true),
            at: CGPoint(x: 10, y: 10)
        )
        try await overEmptySpace(of: workspace, harness: harness, window: window)
        let slot = try XCTUnwrap(
            harness.drag.gridItemFrame(for: .newTab(workspace)), "\(pane.rawValue): no slot was previewed at all"
        )
        if let previous {
            assertSlotFollows(slot, previous, "\(pane.rawValue): the card's last tab")
        }
        if let lands {
            XCTAssertEqual(slot.minX, lands.minX, accuracy: 0.5, "\(pane.rawValue)")
            XCTAssertEqual(slot.minY, lands.minY, accuracy: 0.5, "\(pane.rawValue)")
            XCTAssertEqual(slot.width, lands.width, accuracy: 0.5, "\(pane.rawValue)")
        }
        if let directory, let render {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
        }
        // Released over the gap between the cards, where nothing resolves:
        // this harness has no commit seam to run a real drop through.
        harness.drag.move(to: CGPoint(x: 5, y: 120))
        XCTAssertNil(harness.drag.target)
        harness.drag.release()
        await settle(window)
    }

    /// A tab dropped back in its own gap commits nothing, so its card
    /// previews nothing: no cell slides and the card does not outline itself,
    /// even though the drag still resolves to that card. The preview keys on
    /// the plan, the way every other grid preview does.
    func testACardPreviewsNothingForAReorderThatMovesNoTab() async throws {
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame)
        let cells = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.repoTools }?.tabs)
        let first = cells[0].frame
        // The card's own border, on the edge furthest from the proxy: accent
        // while the card takes a drop, `paneBorder` otherwise.
        let border = CGPoint(x: card.maxX - ChromeMetrics.ruleWidth / 4, y: card.midY)
        let atRest = try snapshot(window)
        XCTAssertEqual(hex(atRest, border), Theme.tokyoNight.palette.chromeRoles.paneBorder.hex)

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: first.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: first.midX, y: first.minY + ChromeMetrics.Grid.tabStripHeight / 2),
            home: DragCoordinator.DragHome(atStart: first, item: .tab(GridFixture.agentsTab), boxInItem: CGRect(origin: .zero, size: first.size))
        )
        // Left of its own centre: the gap before the slot it already holds.
        let target = DropTarget.tabStrip(workspace: GridFixture.repoTools, insertIndex: 0)
        harness.drag.move(to: CGPoint(x: first.midX - 10, y: first.midY))
        XCTAssertEqual(harness.drag.target, target, "it still resolves to a reorder in this card")
        guard case .failure(.noOp) = plan(dragging: .tab(GridFixture.agentsTab), onto: target, model: model) else {
            return XCTFail("a tab dropped in its own gap has to plan nothing, or this test proves nothing")
        }
        await settle(window)

        XCTAssertEqual(
            hex(try snapshot(window), border), hex(atRest, border),
            "the card outlined itself for a drop that commits nothing"
        )
        // The focused tab is still in slot 1 (its bar is there, faded with the
        // origin) and slot 2 still carries no bar at all.
        let mid = try snapshot(window)
        XCTAssertNotEqual(
            hex(mid, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the focused tab left the slot it still holds"
        )
        XCTAssertEqual(
            hex(mid, Self.focusBarPoint(of: cells[1].frame)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "a cell slid for a drop that moves nothing"
        )
        window.close()
    }

    /// A thumbnail is the same size at every window and the row holds as many
    /// as fit. Driven at three window widths through the real view, so the
    /// arithmetic that derives the slot count cannot drift from the width the
    /// cards are actually given.
    func testAThumbnailIsTheSameWidthAtEveryWindowAndTheRowHoldsWhatFits() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()

        /// The cells one card draws in its first row, read off the frames the
        /// view published: its thumbnails plus its trailing tile.
        func firstRow(of harness: Harness, workspace: WorkspaceID, prefix: String) throws -> [CGRect] {
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let card = try XCTUnwrap(grid.cards.first { $0.id == workspace }?.frame)
            let tile = grid.tiles.first { $0.id == workspace }?.frame
            let thumbnails = grid.thumbnails.filter { $0.id.rawValue.hasPrefix(prefix) }.map(\.frame)
            let cells = thumbnails + (tile.map { [$0] } ?? [])
            let top = try XCTUnwrap(cells.map(\.minY).min())
            XCTAssertTrue(cells.allSatisfy { card.contains($0.origin) }, "a cell outside its own card")
            return cells.filter { $0.minY == top }.sorted { $0.minX < $1.minX }
        }

        var drawn: [CGFloat: [CGRect]] = [:]
        // 900 is the narrowest the app allows (`MainWindow` sets that
        // minimum), so it is the narrow case as well as the design one. 1090
        // is a width whose row is a few points short of a fifth slot: it is
        // rendered like the rest but it is here for the overrun check, since
        // that is where an over-generous slot count shows up as real points.
        let rendered: Set<CGFloat> = [Self.windowSize.width, 1200, 1600]
        for width in [Self.windowSize.width, 1090, 1200, 1600] as [CGFloat] {
            let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
            let window = harness.makeWindow(size: CGSize(width: width, height: Self.windowSize.height))
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            // The nine-tab card, which is over its cap at every width here, so
            // its row is full and its last slot is the tile.
            let row = try firstRow(of: harness, workspace: GridFixture.repoTools, prefix: "w1:")
            drawn[width] = row
            for cell in row {
                XCTAssertEqual(
                    cell.width, ChromeMetrics.Grid.thumbnailWidth, accuracy: 0.5,
                    "\(width): a cell is not the one thumbnail width"
                )
            }
            // One slot too many costs real points: the cells run past their
            // card's padding, and the cards then run past the grid's. Both
            // ends are checked, since SwiftUI spends the overrun on whichever
            // has slack. This is what pins the derived slot count against the
            // width a row is actually given.
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let card = try XCTUnwrap(grid.cards.first { $0.id == GridFixture.repoTools }?.frame)
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(row.last).maxX, card.maxX - ChromeMetrics.Grid.cardHorizontalPadding + 0.5,
                "\(width): the row ran past its card"
            )
            // And the derivation itself, against the card the view really
            // laid out: this is the one piece of arithmetic between the width
            // the grid measures and the width a row is given.
            XCTAssertEqual(
                GridCardLayout.rowWidth(
                    gridWidth: grid.viewport.width, canvasPadding: ChromeMetrics.Grid.canvasPadding,
                    cardGap: ChromeMetrics.Grid.cardGap, cardPadding: ChromeMetrics.Grid.cardHorizontalPadding
                ),
                card.width - ChromeMetrics.Grid.cardHorizontalPadding * 2, accuracy: 0.5,
                "\(width): the derived row width is not the width a card gives its row"
            )
            if let directory, rendered.contains(width) {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-\(Int(width)).png"))
            }
            window.close()
        }

        let design = try XCTUnwrap(drawn[Self.windowSize.width])
        let middle = try XCTUnwrap(drawn[1200])
        let wide = try XCTUnwrap(drawn[1600])
        XCTAssertEqual(design.count, 4, "the narrowest window the app allows lost its shape")
        XCTAssertGreaterThan(middle.count, design.count, "a wider window drew no more cells")
        XCTAssertGreaterThan(wide.count, middle.count, "a wider window still drew no more cells")
        XCTAssertEqual(
            Set(drawn.values.flatMap { $0 }.map { ($0.width * 100).rounded() }).count, 1,
            "a thumbnail changed size between windows"
        )
    }

    /// A pane aimed INSIDE another tab's thumbnail: the mini pane under the
    /// pointer answers, on the canvas's own rules, and the slot the thumbnail
    /// opens is the one that aim produces. Two aims, two renders: a mini
    /// pane's top edge, and the middle of the same pane.
    func testAPaneAimedAtAMiniPaneOpensTheSlotThatAimProduces() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let grabbed = try XCTUnwrap(
            harness.drag.surfaces?.grid?.miniPaneFrame(of: GridFixture.claudePane), "the pane being dragged"
        )
        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.testsTab }?.frame)
        XCTAssertEqual(target.height, ChromeMetrics.Grid.thumbnailHeight)
        XCTAssertEqual(target.width, 93, accuracy: 1, "the thumbnail the pure band tests are sized against")

        // The view's own published boxes, not a second layout pass: this is
        // what the resolver is actually hit-testing against.
        let drawn = try XCTUnwrap(harness.drag.surfaces?.grid?.miniPanes.first { $0.tab == GridFixture.testsTab })
        XCTAssertEqual(drawn.panes.count, 2, "the fixture's tests tab draws two mini panes")
        let left = try XCTUnwrap(drawn.panes.min { $0.frame.minX < $1.frame.minX })
        let right = try XCTUnwrap(drawn.panes.max { $0.frame.minX < $1.frame.minX })
        let leftBox = left.frame.offsetBy(dx: target.minX, dy: target.minY)

        let area = MiniPaneLayout.paneArea(in: target, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        func boxes(arriving: MiniPaneLayout.Arrival?) -> [MiniPaneLayout.Placed] {
            MiniPaneLayout.boxes(
                layout: model.layouts[GridFixture.testsTab], exported: nil, fallbackPanes: [], size: area.size,
                padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2,
                arriving: arriving
            )
        }
        func inWindow(_ box: CGRect) -> CGRect { box.offsetBy(dx: area.minX, dy: area.minY) }
        let resting = boxes(arriving: nil)

        // The proxy is the mini pane's own footprint, as the grid's pane drag
        // makes it: a thumbnail-sized one would cover the panes being sampled.
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: grabbed.size, isCompact: true),
            at: CGPoint(x: grabbed.midX, y: grabbed.midY)
        )
        XCTAssertTrue(source.contains(grabbed), "the grabbed pane is drawn in its own tab's thumbnail")

        /// Drives one aim to its render, and returns the slot the drop opens
        /// and the pane it opened it inside.
        func aim(
            at point: CGPoint, expecting expected: DropTarget, render: String, line: UInt = #line
        ) async throws -> (opened: CGRect, kept: CGRect) {
            harness.drag.move(to: point)
            XCTAssertEqual(harness.drag.target, expected, "the aim did not resolve", line: line)
            let arrival = try XCTUnwrap(MiniPaneLayout.arrival(
                of: harness.drag.activeSubject, onto: harness.drag.target, tab: GridFixture.testsTab, model: model
            ), "nothing previewed", line: line)
            XCTAssertEqual(arrival.target, expected, "the preview left the aim behind", line: line)
            await settle(window)

            let landing = boxes(arriving: arrival)
            let opened = try XCTUnwrap(landing.first { $0.pane == arrival.pane }).frame
            let kept = try XCTUnwrap(landing.first { $0.pane == left.pane }).frame
            XCTAssertEqual(
                landing.first { $0.pane == right.pane }?.frame, resting.first { $0.pane == right.pane }?.frame,
                "the pane the drop was not aimed at moved", line: line
            )

            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
            }
            let slot = inWindow(opened)
            let untouched = inWindow(try XCTUnwrap(landing.first { $0.pane == right.pane }).frame)
            // Sampled at the bottom of each box, clear of the proxy the
            // pointer carries and of a mini pane's own title row.
            XCTAssertLessThanOrEqual(
                channelDistance(
                    hex(image, CGPoint(x: slot.midX, y: slot.maxY - 10)), hex(image, CGPoint(x: slot.midX, y: slot.maxY - 4))
                ),
                Self.washDither, "the slot the arriving pane takes is not one wash", line: line
            )
            XCTAssertGreaterThan(
                channelDistance(
                    hex(image, CGPoint(x: slot.midX, y: slot.maxY - 4)),
                    hex(image, CGPoint(x: untouched.midX, y: untouched.maxY - 4))
                ),
                Self.washDither, "the slot reads the same as a mini pane still standing there", line: line
            )
            return (opened, kept)
        }

        // The top edge of the left mini pane: the slot opens across the top
        // of that pane alone, which no whole-thumbnail drop can produce.
        let edge = try await aim(
            at: CGPoint(x: leftBox.midX, y: leftBox.minY + 2),
            expecting: .paneEdge(left.pane, .top),
            render: "grid-drag-pane-onto-mini-pane-edge.png"
        )
        XCTAssertLessThan(edge.opened.maxY, edge.kept.minY, "the pane made room above itself")
        XCTAssertEqual(edge.opened.minX, left.frame.minX, accuracy: 1, "inside the aimed pane's own column")

        // The middle of the same pane: across tabs that is a `pane.move`
        // naming it, so it divides on the right instead.
        let interior = try await aim(
            at: CGPoint(x: leftBox.midX, y: leftBox.midY),
            expecting: .paneInterior(left.pane),
            render: "grid-drag-pane-onto-mini-pane-interior.png"
        )
        XCTAssertLessThan(interior.kept.maxX, interior.opened.minX, "the pane made room beside itself")
        XCTAssertLessThan(interior.opened.maxX, right.frame.minX, "still inside the aimed pane's own column")
        window.close()
    }

    /// A pane dragged over another tab's thumbnail: that tab's mini panes
    /// make room where herdr will really put it, beside the tab's focused
    /// pane, and the space they give up is drawn as the arriving pane's slot.
    func testAThumbnailOpensTheSplitAnArrivingPaneWillTake() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.testsTab }?.frame)
        let area = MiniPaneLayout.paneArea(in: target, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        func boxes(arriving: MiniPaneLayout.Arrival?) -> [MiniPaneLayout.Placed] {
            MiniPaneLayout.boxes(
                layout: model.layouts[GridFixture.testsTab], exported: nil, fallbackPanes: [], size: area.size,
                padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2,
                arriving: arriving
            )
        }
        func inWindow(_ box: CGRect) -> CGRect { box.offsetBy(dx: area.minX, dy: area.minY) }

        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )
        // Aimed at the target's handle strip rather than its middle: the
        // proxy is centred on the pointer and a thumbnail's own size, so a
        // pointer in the middle would cover the very panes being sampled.
        harness.drag.move(to: CGPoint(x: target.midX, y: target.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(harness.drag.target, .tabThumbnail(GridFixture.testsTab))
        let arrival = try XCTUnwrap(MiniPaneLayout.arrival(
            of: harness.drag.activeSubject, onto: harness.drag.target, tab: GridFixture.testsTab, model: model
        ))
        let focused = try XCTUnwrap(model.layouts[GridFixture.testsTab]?.focusedPane)
        XCTAssertEqual(arrival.target, .paneEdge(focused, .right))
        await settle(window)

        let resting = boxes(arriving: nil)
        let landing = boxes(arriving: arrival)
        let gaveUp = try XCTUnwrap(resting.first { $0.pane == focused }).frame
        let kept = try XCTUnwrap(landing.first { $0.pane == focused }).frame
        let landed = try XCTUnwrap(landing.first { $0.pane == arrival.pane }).frame
        XCTAssertLessThan(kept.width, gaveUp.width, "the focused pane did not make room")

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-pane-into-tab.png"))
        }

        let opened = inWindow(landed)
        let untouched = inWindow(try XCTUnwrap(landing.first { ![arrival.pane, focused].contains($0.pane) }).frame)
        // Both samples sit in the bottom of their box, below the proxy and
        // below a mini pane's own title row.
        XCTAssertEqual(
            hex(image, CGPoint(x: opened.midX, y: opened.maxY - 14)), hex(image, CGPoint(x: opened.midX, y: opened.maxY - 4)),
            "the slot the arriving pane takes is one flat wash"
        )
        XCTAssertNotEqual(
            hex(image, CGPoint(x: opened.midX, y: opened.maxY - 4)), hex(image, CGPoint(x: untouched.midX, y: untouched.maxY - 4)),
            "the slot reads the same as a mini pane still standing there"
        )
        window.close()
    }

    /// The focus bar's own pixel inside a thumbnail's handle strip: the bar
    /// is drawn at the strip's leading edge, inside its padding.
    private static func focusBarPoint(of thumbnail: CGRect) -> CGPoint {
        CGPoint(
            x: thumbnail.minX + ChromeMetrics.Grid.tabStripHorizontalPadding + ChromeMetrics.Grid.tabStripIndicatorSize.width / 2,
            y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2
        )
    }

    /// The placeholder's frame against the frame the real tab takes, from
    /// real reported frames on both sides. The expanded card's collapse tile
    /// sits in exactly the slot the tenth tab will land in, so its rect
    /// BEFORE the drag is the answer to compare against.
    func testTheNewTabPlaceholderTakesTheSlotTheTabWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        harness.drag.toggleGridCard(GridFixture.repoTools)
        await settle(window)

        // Nine tabs plus the collapse tile fill ten slots, so the tile holds
        // the slot the tenth tab takes. Read before anything is dragged.
        let landing = try XCTUnwrap(harness.drag.surfaces?.grid?.tiles.first { $0.id == GridFixture.repoTools }?.frame)
        let herdrTabs = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.filter { $0.id.rawValue.hasPrefix("w4:") })
        let lastHerdrTab = try XCTUnwrap(herdrTabs.map(\.frame).max { $0.minX < $1.minX })

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )

        try await overEmptySpace(of: GridFixture.repoTools, harness: harness, window: window)
        let expandedPlaceholder = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)))
        XCTAssertEqual(expandedPlaceholder.minX, landing.minX, accuracy: 0.5, "the slot the tenth tab lands in")
        XCTAssertEqual(expandedPlaceholder.minY, landing.minY, accuracy: 0.5)
        XCTAssertEqual(expandedPlaceholder.width, landing.width, accuracy: 0.5)
        XCTAssertEqual(expandedPlaceholder.height, landing.height, accuracy: 0.5)

        let movedTile = try XCTUnwrap(harness.drag.surfaces?.grid?.tiles.first { $0.id == GridFixture.repoTools }?.frame)
        assertSlotFollows(movedTile, expandedPlaceholder, "the placeholder that took its slot")
        let expanded = try snapshot(window)
        if let directory {
            try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-new-tab.png"))
        }

        // A resting card under its cap draws the tab, so the placeholder
        // stands in the next slot of the row it is already in.
        try await overEmptySpace(of: GridFixture.herdr, harness: harness, window: window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)), "the placeholder left with the card it was over")
        let resting = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.herdr)))
        assertSlotFollows(resting, lastHerdrTab, "the card's last tab")

        // A resting card whose row is already full hides the tab it would
        // create, so it shows no placeholder and keeps its single row. It has
        // no tile either, so nothing carries the preview but its outline.
        try await assertNoPlaceholderAndNoNewRow(
            on: GridFixture.mattstackApps, harness: harness, window: window, directory: nil, render: nil
        )

        // A resting card already over its cap draws no tab either, but it has
        // a "+N" tile, and that tile is where the created tab really lands:
        // it gives up its own face for the new tab's while the drop is live.
        try await assertNoPlaceholderAndNoNewRow(
            on: GridFixture.paddock, harness: harness, window: window,
            directory: directory, render: "grid-drag-resting-card.png"
        )
        window.close()
    }

    /// Moves the drag onto a card that will not draw the tab it creates, and
    /// pins that the card shows no placeholder and does not grow. A card with
    /// a tile also has to light that tile, which is the only preview such a
    /// drop can honestly carry.
    private func assertNoPlaceholderAndNoNewRow(
        on workspace: WorkspaceID, harness: Harness, window: NSWindow, directory: String?, render: String?
    ) async throws {
        let before = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        // A sibling thumbnail's own ground is the control: it carries the
        // card's wash and nothing else, so the tile can only differ from it by
        // taking a second one. Both are the same role at rest, which the
        // before-sample pins rather than assumes.
        // The cell that should light, and a control that should not: two cells
        // of the same card sharing a ground, so only a second wash can part
        // them. A card with no tile has nothing that may light, so the two
        // controls have to stay equal instead.
        let siblings = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails
            .filter { $0.id.rawValue.hasPrefix("\(workspace.rawValue):") }.map(\.frame))
        let tile = harness.drag.surfaces?.grid?.tiles.first { $0.id == workspace }?.frame
        let lights = tile ?? siblings.first
        let control = try XCTUnwrap(tile == nil ? siblings.dropFirst().first : siblings.first)
        let atRest = try snapshot(window)
        XCTAssertEqual(
            hex(atRest, groundPoint(of: try XCTUnwrap(lights))), hex(atRest, groundPoint(of: control)),
            "\(workspace.rawValue): the two sampled cells do not share a ground at rest, so the check below proves nothing"
        )

        try await overEmptySpace(of: workspace, harness: harness, window: window)
        let after = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        XCTAssertEqual(after.height, before.height, accuracy: 0.5, "\(workspace.rawValue) grew a row the drop will not keep")

        // Whatever stands in for the created tab is also where a committed
        // drop lands. A card with a tile publishes the tile's own rect under
        // that id, from the real view rather than a written-in frame; a card
        // with nothing to stand in has no rect at all and falls back to
        // itself.
        if let tile {
            XCTAssertEqual(
                harness.drag.gridItemFrame(for: .newTab(workspace)), tile,
                "\(workspace.rawValue)'s tile carries the drop but never published its rect for it"
            )
        } else {
            XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(workspace)), "\(workspace.rawValue)")
        }

        let image = try snapshot(window)
        let lit = hex(image, groundPoint(of: try XCTUnwrap(lights)))
        let unlit = hex(image, groundPoint(of: control))
        if let tile {
            XCTAssertNotEqual(lit, unlit, "\(workspace.rawValue)'s tile did not take the drop wash the card's other cells do without")
            // The tile is wearing the new tab's face, not just a wash: only
            // that face carries a handle strip, which is a second coat over
            // its own body. Sampled at the band's trailing end, clear of the
            // "new tab" label. At rest the tile's own face has no band at all,
            // which the before-sample pins.
            let band = CGPoint(
                x: tile.maxX - ChromeMetrics.Grid.tabStripHorizontalPadding - 1,
                y: tile.minY + ChromeMetrics.Grid.tabStripHeight / 2
            )
            XCTAssertEqual(
                hex(atRest, band), hex(atRest, groundPoint(of: tile)),
                "\(workspace.rawValue): the tile already had a band at rest, so the check below proves nothing"
            )
            XCTAssertNotEqual(
                hex(image, band), lit,
                "\(workspace.rawValue)'s tile only washed: it did not take the new tab's own face"
            )
        } else {
            XCTAssertEqual(unlit, lit, "\(workspace.rawValue) has no tile, so nothing inside it may take a second wash")
        }
        if let directory, let render {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
        }
    }

    /// The largest per-channel gap between two sampled hexes. A blend against
    /// whatever is behind moves every channel; a shadow's bleed moves them by
    /// a unit or two, which is what this has to stay clear of.
    private func channelDistance(_ lhs: String, _ rhs: String) -> Int {
        func channels(_ hex: String) -> [Int] {
            let digits = Array(hex.dropFirst())
            return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
        }
        return zip(channels(lhs), channels(rhs)).map { abs($0 - $1) }.max() ?? 0
    }

    /// A cell's own ground: the BOTTOM-left corner, two points in. A
    /// thumbnail's top is its handle strip and its middle is mini panes, so
    /// only the padding below them is the ground a tile can be compared with.
    private func groundPoint(of cell: CGRect) -> CGPoint {
        CGPoint(x: cell.minX + 2, y: cell.maxY - 2)
    }

    /// A drop the planner refuses must promise nothing: no placeholder and no
    /// wash. It resolves to the card like any other, so a preview keyed on the
    /// resolved target alone would draw for it.
    func testACardPreviewsNothingForADropThePlannerRefuses() async throws {
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        // A multi-pane tab into ANOTHER workspace: this fixture carries no
        // split tree, so `planTabMigration` refuses the shape outright and
        // the card may not outline, wash or open a slot for it.
        let other = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        let refusedGround = Self.headerGround(of: other)
        // Clear of the proxy, which hangs from the pointer: the card's own
        // fill at its leading edge, on the same row.
        let refusedSample = CGPoint(x: other.minX + ChromeMetrics.Grid.cardHorizontalPadding / 2, y: refusedGround.y)
        let refusedAtRest = hex(try snapshot(window), refusedSample)
        let multiPane = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: multiPane.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: multiPane.midX, y: multiPane.minY + ChromeMetrics.Grid.tabStripHeight / 2)
        )
        harness.drag.move(to: refusedGround)
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps), "it still resolves to the card")
        guard case .failure = plan(dragging: .tab(GridFixture.agentsTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model) else {
            return XCTFail("the fixture grew a split tree, so this drop now commits and previews nothing wrongly")
        }
        await settle(window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(GridFixture.mattstackApps)), "a refused plan may not promise a tab")
        XCTAssertEqual(hex(try snapshot(window), refusedSample), refusedAtRest, "nor wash the card it will not change")
        // Released over the gap between the cards, where nothing resolves:
        // this harness has no commit seam to run a real drop through.
        harness.drag.move(to: CGPoint(x: 5, y: 120))
        XCTAssertNil(harness.drag.target)
        harness.drag.release()
        await settle(window)

        window.close()
    }

    /// The grid on the other side of the ladder, and on the theme where the
    /// handle strip's title has the least headroom of the seventeen. Every
    /// other grid render is Tokyo Night, which is where the strip's role was
    /// measured, so neither of these is the theme the choice was made on.
    func testTheGridRendersInALightThemeAndInTheTightestDarkOne() async throws {
        try await renderGrid(themed: "catppuccin-latte", into: "grid-rest-latte.png")
        try await renderGrid(themed: "nord", into: "grid-rest-nord.png")
    }

    private func renderGrid(themed id: String, into file: String) async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
        let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
        assertGridSamples(image, theme: theme)

        // The strip is a band, not the body it sits on: sampled inside a
        // thumbnail's strip and inside the same thumbnail's ground. The
        // sample sits in the run between the title and the status dot, clear
        // of both, since either would be its own colour.
        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let beforeTheDot = ChromeMetrics.Grid.tabStripHorizontalPadding
            + ChromeMetrics.Grid.labelStatusDot + ChromeMetrics.Grid.tabStripSpacing
        let strip = hex(image, CGPoint(x: thumbnail.maxX - beforeTheDot, y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(strip, theme.palette.chromeRoles.tabStripFill.hex, "\(id): the strip carries the role it was given")
        XCTAssertNotEqual(strip, theme.palette.chromeRoles.canvas.hex, "\(id): and it is not the thumbnail body")
        window.close()
    }

    /// A whole tab dragged by its handle strip is proxied as a miniature of
    /// its own thumbnail, at that thumbnail's exact frame. The compact cap
    /// would shrink it, which would read as a different tab than the one the
    /// drop is aimed beside.
    func testATabDraggedFromItsHandleStripIsProxiedAsAMiniatureOfItself() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let model = try GridFixture.model()
        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let area = MiniPaneLayout.paneArea(
            in: CGRect(origin: .zero, size: source.size), stripHeight: ChromeMetrics.Grid.tabStripHeight
        )
        let panes = MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: area.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        ).compactMap { placed -> DragCoordinator.Ghost.TabMiniature.Pane? in
            guard let pane = model.panes[placed.pane] else { return nil }
            return .init(title: pane.displayTitle, status: pane.agentStatus, box: placed.frame)
        }
        XCTAssertEqual(panes.count, 3, "the fixture tab's own three panes")

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: source.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: panes)
            ),
            at: CGPoint(x: source.midX, y: source.minY + ChromeMetrics.Grid.tabStripHeight / 2)
        )
        let ghost = try XCTUnwrap(harness.drag.ghost)
        XCTAssertEqual(
            DragVisuals.ghostSize(forOrigin: ghost.originSize, bounds: ghost.bounds), source.size,
            "the proxy is the thumbnail it was picked up from, one to one"
        )

        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        harness.drag.move(to: CGPoint(
            x: target.midX,
            y: target.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        ))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps))
        // This fixture's tabs carry no split tree, so a MULTI-pane tab cannot
        // be migrated and the card it is over is left unlit. That is the
        // preview keying on the plan; the render is here for the proxy, and
        // a single-pane tab is what proves the lit path.
        guard case .failure = plan(
            dragging: .tab(GridFixture.agentsTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model
        ) else {
            return XCTFail("the fixture grew a split tree, so this render's card would now light")
        }
        guard case .success = plan(
            dragging: .tab(GridFixture.glanceTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model
        ) else {
            return XCTFail("a single-pane tab migrating into another workspace has to commit")
        }
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-tab.png"))
        }

        // The proxy is a thumbnail's size and centred on the pointer, so it
        // covers what it is aimed at: its own band has to let that through.
        // An opaque one would paint the fill role exactly.
        // Clear of both the title and the status dot, so the sample is the
        // band's own fill rather than an antialiased glyph edge.
        let proxy = try XCTUnwrap(harness.drag.ghostTopLeft)
        let band = CGPoint(x: proxy.x + source.width - 18, y: proxy.y + ChromeMetrics.Grid.tabStripHeight / 2)
        XCTAssertGreaterThan(
            channelDistance(hex(image, band), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex), 8,
            "the proxy's band reads as its own opaque fill, so nothing under the proxy shows through"
        )
        window.close()
    }

    /// Moves the live drag onto a card's own empty space, which is its header
    /// row: no thumbnail or tile covers it.
    private func overEmptySpace(of workspace: WorkspaceID, harness: Harness, window: NSWindow) async throws {
        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        harness.drag.move(to: Self.headerGround(of: card))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(workspace))
        await settle(window)
    }

    /// A card's own empty space: the middle of its header row, which no
    /// thumbnail or tile covers.
    private static func headerGround(of card: CGRect) -> CGPoint {
        CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        )
    }

    /// Two cells of one row: same top edge and height, one `tabGap` apart.
    private func assertSlotFollows(_ slot: CGRect, _ previous: CGRect, _ label: String) {
        XCTAssertEqual(slot.minY, previous.minY, accuracy: 0.5, "same row as \(label)")
        XCTAssertEqual(slot.height, previous.height, accuracy: 0.5, "same height as \(label)")
        XCTAssertEqual(slot.width, previous.width, accuracy: 0.5, "same width as \(label)")
        XCTAssertEqual(slot.minX, previous.maxX + ChromeMetrics.Grid.tabGap, accuracy: 0.5, "the slot after \(label)")
    }

    /// Points are top-left in the 900x560 window: the title bar, the grid
    /// header over its rule, the canvas margin, and the first card's border,
    /// fill and focused accent bar.
    private func assertGridSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let samples: [(String, CGPoint, RGB)] = [
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/header", CGPoint(x: 450, y: 28), roles.chrome),
            ("rule/header", CGPoint(x: 450, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 5, y: 120), roles.canvas),
            ("paneBorder/card", CGPoint(x: 13.25, y: 150), roles.paneBorder),
            ("pane/card", CGPoint(x: 18, y: 80), roles.pane),
            ("accent/focusedBar", CGPoint(x: 27.5, y: 94), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    // MARK: - Helpers

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the role hexes.
    private func snapshot(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView?.superview)
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

    /// Straight from the bitmap's bytes, with no color-space conversion on the
    /// way out.
    /// How far apart two sampled colours may be and still be the same
    /// surface. A low-opacity wash over a dark ground does not composite to
    /// one exact byte across a region, so an exact comparison reads the
    /// renderer's own dither as a difference; a genuinely different surface
    /// is tens of units away.
    private static let washDither = 2

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat = 2) -> String {
        guard let data = image.bitmapData else { return "?" }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    /// Points are top-left, in the 900x560 window. Indicator samples sit on
    /// each row's 3x15 bar: the selected row is accent, the others take the
    /// fixture's workspace status. Rows start at y 61 on a 28pt pitch; tabs
    /// start at x 203 on a 103pt pitch, 28 tall on a strip spanning y 26 to 62.
    private func assertSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let palette = theme.palette
        let samples: [(String, CGPoint, RGB)] = [
            ("indicator/selected", CGPoint(x: 21, y: 74), roles.accent),
            ("indicator/blocked", CGPoint(x: 21, y: 102), palette.red),
            ("indicator/working", CGPoint(x: 21, y: 130), palette.yellow),
            ("indicator/done", CGPoint(x: 21, y: 158), palette.teal),
            ("indicator/idle", CGPoint(x: 21, y: 186), roles.chrome),
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/strip", CGPoint(x: 700, y: 30), roles.chrome),
            ("chrome/rail", CGPoint(x: 75, y: 400), roles.chrome),
            ("rule/rail", CGPoint(x: 192.25, y: 400), roles.rule),
            ("selection/row", CGPoint(x: 100, y: 64), roles.selection),
            ("tabRest", CGPoint(x: 253, y: 40), roles.tabRest),
            ("selection/tab", CGPoint(x: 459, y: 40), roles.selection),
            ("accent/underline", CGPoint(x: 459, y: 61.25), roles.accent),
            ("rule/strip", CGPoint(x: 700, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 196, y: 400), roles.canvas),
            ("paneBorder", CGPoint(x: 199.25, y: 400), roles.paneBorder),
            ("pane", CGPoint(x: 300, y: 400), roles.pane),
            ("canvas/gutter", CGPoint(x: 546, y: 400), roles.canvas),
            ("accent/focusedLeading", CGPoint(x: 551.25, y: 400), roles.accent),
            ("accent/focused", CGPoint(x: 893.25, y: 400), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    private func assertButtonsCentered(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        for button in buttons {
            let inWindow = button.convert(button.bounds, to: nil)
            let centerFromTop = window.frame.height - inWindow.midY
            XCTAssertEqual(centerFromTop, ChromeMetrics.TitleBar.height / 2, accuracy: 0.5, "\(button.frame)", file: file, line: line)
        }
    }

    /// Every visible view of ours under a top-left window point, the content
    /// view included: the views whose `mouseDownCanMoveWindow` decides whether
    /// a press there moves the window.
    private func contentViews(at point: CGPoint, in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        let windowPoint = NSPoint(x: point.x, y: window.frame.height - point.y)
        var found: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view.convert(view.bounds, to: nil).contains(windowPoint) {
                found.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}

@MainActor
private struct Harness {
    let themeStore: ThemeStore
    let textSize: TerminalTextSizeStore
    let toasts: ToastCenter
    let rearrange: RearrangeMode
    let drag: DragCoordinator
    let dividerDrag: DividerDragCoordinator
    let viewModel: SessionViewModel

    init(
        theme: Theme, model: SessionModel? = nil, client: any HerdrCommandClient = OfflineHerdrClient(),
        attaching panes: [PaneID] = Fixture.canvasPanes
    ) async throws {
        ChromeType.install()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }))
        viewModel = SessionViewModel(client: client, ghosttyFactory: GroundSurfaceFactory())
        viewModel.update(model: try model ?? Fixture.model(), connection: .live)
        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
    }

    func makeWindow(size: CGSize) -> NSWindow {
        let root = MainWindow(viewModel: viewModel, sessionLabel: "render")
            .environment(themeStore)
            .environment(textSize)
            .environment(toasts)
            .environment(rearrange)
            .environment(drag)
            .environment(dividerDrag)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

private struct OfflineHerdrClient: HerdrCommandClient {
    struct Offline: Error {}

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw Offline()
    }
}

@MainActor
private final class GroundSurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}

/// Answers the hover card's last-line read and nothing else.
private struct GridFixtureClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { throw OfflineHerdrClient.Offline() }
        return Data(#"{"result":{"text":"Editing lib/daemon.ts\n"}}"#.utf8)
    }
}

/// Six workspaces, one with nine tabs and one with six, over split layouts
/// and every agent status.
private enum GridFixture {
    static let repoTools = WorkspaceID(rawValue: "w1")
    /// Six tabs: a resting card already over its cap, so it draws a "+N" tile.
    static let paddock = WorkspaceID(rawValue: "w2")
    static let mattstackApps = WorkspaceID(rawValue: "w3")
    /// Three tabs: a resting card still under its visible-tab cap. `src`
    /// holds one pane (a drop from it empties the tab), `build` holds two.
    static let herdr = WorkspaceID(rawValue: "w4")
    static let srcTab = TabID(rawValue: "w4:t1")
    static let buildTab = TabID(rawValue: "w4:t2")
    static let issuesTab = TabID(rawValue: "w4:t3")
    static let srcPane = PaneID(rawValue: "w4:p1")
    static let buildPane = PaneID(rawValue: "w4:p2")
    /// One tab holding one pane: the card whose own drop adds it nothing.
    static let glance = WorkspaceID(rawValue: "w6")
    static let glanceTab = TabID(rawValue: "w6:t1")
    static let glancePane = PaneID(rawValue: "w6:p1")
    static let agentsTab = TabID(rawValue: "w1:t1")
    static let migrationTab = TabID(rawValue: "w2:t1")
    /// Two panes side by side: a tab with a pane to make room and a pane that
    /// must not move.
    static let testsTab = TabID(rawValue: "w2:t2")
    static let claudePane = PaneID(rawValue: "w1:p1")

    private typealias Rect = (x: Int, y: Int, width: Int, height: Int)
    private static let whole: [Rect] = [(0, 0, 80, 24)]
    private static let sideBySide: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 24)]
    private static let stacked: [Rect] = [(0, 0, 80, 12), (0, 12, 80, 12)]
    private static let leftAndStack: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 12), (40, 12, 40, 12)]

    private static let workspaces: [(label: String, status: String, tabs: [(label: String, status: String, shape: [Rect], panes: [(String, String)])])] = [
        ("repo-tools", "working", [
            ("agents", "working", leftAndStack, [("claude", "working"), ("bun test", "done"), ("nvim", "idle")]),
            ("server", "blocked", whole, [("codex", "blocked")]),
            ("scratch", "idle", stacked, [("bun dev", "working"), ("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("bun test", "done"), ("nvim", "idle")]),
            ("docs", "blocked", whole, [("claude", "working")]),
            ("release", "idle", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bench", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
            ("ci", "idle", leftAndStack, [("zsh", "idle"), ("tail -f", "idle"), ("claude", "working")]),
            ("notes", "done", whole, [("zsh", "idle")]),
        ]),
        ("paddock", "blocked", [
            ("migration", "working", whole, [("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("tail -f", "idle"), ("claude", "working")]),
            ("design", "done", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bridge", "idle", whole, [("zsh", "idle")]),
            ("logs", "blocked", whole, [("tail -f", "blocked")]),
            ("review", "idle", whole, [("codex", "idle")]),
        ]),
        ("mattstack-apps", "done", [
            ("tray", "working", whole, [("codex", "blocked")]),
            ("console", "idle", sideBySide, [("bun dev", "working"), ("zsh", "idle")]),
            ("deck", "done", stacked, [("tail -f", "idle"), ("claude", "working")]),
            ("board", "idle", leftAndStack, [("bun test", "done"), ("nvim", "idle"), ("codex", "blocked")]),
        ]),
        ("herdr", "idle", [
            ("src", "working", whole, [("bun dev", "working")]),
            ("build", "idle", sideBySide, [("zsh", "idle"), ("tail -f", "idle")]),
            ("issues", "done", stacked, [("claude", "working"), ("bun test", "done")]),
        ]),
        ("console", "working", [
            ("dev", "idle", whole, [("nvim", "idle")]),
            ("storybook", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
        ]),
        ("glance", "idle", [
            ("shell", "idle", whole, [("zsh", "idle")]),
        ]),
    ]

    static func model() throws -> SessionModel {
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        var layouts: [[String: Any]] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspaceID = "w\(workspaceIndex + 1)"
            workspaceRows.append([
                "workspace_id": workspaceID, "label": workspace.label, "number": workspaceIndex + 1,
                "active_tab_id": "\(workspaceID):t1", "agent_status": workspace.status,
            ])
            var paneNumber = 0
            for (tabIndex, tab) in workspace.tabs.enumerated() {
                let tabID = "\(workspaceID):t\(tabIndex + 1)"
                tabRows.append([
                    "tab_id": tabID, "workspace_id": workspaceID, "label": tab.label, "number": tabIndex + 1,
                    "pane_count": tab.panes.count, "agent_status": tab.status,
                ])
                var rects: [[String: Any]] = []
                for (rect, pane) in zip(tab.shape, tab.panes) {
                    paneNumber += 1
                    let paneID = "\(workspaceID):p\(paneNumber)"
                    paneRows.append([
                        "pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": paneID == "w1:p1",
                        "agent_status": pane.1, "revision": 1, "terminal_title_stripped": pane.0,
                        "cwd": NSHomeDirectory() + "/Documents/GitHub/\(workspace.label)",
                    ])
                    rects.append([
                        "pane_id": paneID, "focused": false,
                        "rect": ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height],
                    ])
                }
                layouts.append([
                    "workspace_id": workspaceID, "tab_id": tabID, "zoomed": false,
                    "area": ["x": 0, "y": 0, "width": 80, "height": 24], "panes": rects, "splits": [],
                ])
            }
        }
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t1",
            "focused_pane_id": "w1:p1", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": layouts,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}

private enum Fixture {
    static let canvasPanes = [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")]

    static func model() throws -> SessionModel {
        let workspaces: [(id: String, label: String, panes: Int, status: String)] = [
            ("w1", "paddock", 5, "idle"), ("w2", "repo-tools", 3, "blocked"), ("w3", "board", 2, "working"),
            ("w4", "mattstack-apps", 4, "done"), ("w5", "herdr", 1, "idle"),
        ]
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        for (index, workspace) in workspaces.enumerated() {
            let isPaddock = workspace.id == "w1"
            let tabLabels = isPaddock ? ["api", "web", "claude", "logs"] : ["main"]
            workspaceRows.append([
                "workspace_id": workspace.id, "label": workspace.label, "number": index + 1,
                "active_tab_id": isPaddock ? "w1:t3" : "\(workspace.id):t1", "agent_status": workspace.status,
            ])
            for (tabIndex, label) in tabLabels.enumerated() {
                tabRows.append([
                    "tab_id": "\(workspace.id):t\(tabIndex + 1)", "workspace_id": workspace.id, "label": label,
                    "number": tabIndex + 1, "pane_count": 1, "agent_status": "idle",
                ])
            }
            let paddockTabs = ["w1:t3", "w1:t3", "w1:t1", "w1:t2", "w1:t4"]
            for paneIndex in 0..<workspace.panes {
                paneRows.append([
                    "pane_id": "\(workspace.id):p\(paneIndex + 1)", "workspace_id": workspace.id,
                    "tab_id": isPaddock ? paddockTabs[paneIndex] : "\(workspace.id):t1",
                    "focused": isPaddock && paneIndex == 1, "agent_status": "idle", "revision": 1,
                    "terminal_title_stripped": "shell", "cwd": "/private/tmp",
                ])
            }
        }
        let area: [String: Int] = ["x": 0, "y": 0, "width": 120, "height": 40]
        let layout: [String: Any] = [
            "workspace_id": "w1", "tab_id": "w1:t3", "zoomed": false, "area": area, "focused_pane_id": "w1:p2",
            "panes": [
                ["pane_id": "w1:p1", "focused": false, "rect": ["x": 0, "y": 0, "width": 60, "height": 40]],
                ["pane_id": "w1:p2", "focused": true, "rect": ["x": 60, "y": 0, "width": 60, "height": 40]],
            ],
            "splits": [["id": "split_0_root", "direction": "right", "ratio": 0.5, "rect": area]],
        ]
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t3",
            "focused_pane_id": "w1:p2", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": [layout],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}
