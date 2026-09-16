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

        let target = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.migrationTab }?.frame)
        harness.drag.move(to: CGPoint(x: target.midX, y: target.midY))
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
        // a "+N" tile, and that count is the one thing the drop visibly
        // changes: the tile takes the wash a targeted thumbnail gets.
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
        let tile = harness.drag.surfaces?.grid?.tiles.first { $0.id == workspace }?.frame
        let sibling = harness.drag.surfaces?.grid?.thumbnails
            .first { $0.id.rawValue.hasPrefix("\(workspace.rawValue):") }?.frame
        let atRest = try snapshot(window)
        if let tile, let sibling {
            XCTAssertEqual(
                hex(atRest, groundPoint(of: tile)), hex(atRest, groundPoint(of: sibling)),
                "\(workspace.rawValue): tile and thumbnail do not share a ground at rest, so the wash check below proves nothing"
            )
        }

        try await overEmptySpace(of: workspace, harness: harness, window: window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(workspace)), "\(workspace.rawValue)")
        let after = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        XCTAssertEqual(after.height, before.height, accuracy: 0.5, "\(workspace.rawValue) grew a row the drop will not keep")

        let image = try snapshot(window)
        if let tile, let sibling {
            XCTAssertNotEqual(
                hex(image, groundPoint(of: tile)), hex(image, groundPoint(of: sibling)),
                "\(workspace.rawValue)'s tile did not take the drop wash the card's other cells do without"
            )
        }
        if let directory, let render {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
        }
    }

    /// A cell's own ground: the BOTTOM-left corner, two points in. A
    /// thumbnail's top is its handle strip and its middle is mini panes, so
    /// only the padding below them is the ground a tile can be compared with.
    private func groundPoint(of cell: CGRect) -> CGPoint {
        CGPoint(x: cell.minX + 2, y: cell.maxY - 2)
    }

    /// The grid in a light theme. The handle strip's fill has to separate
    /// from the thumbnail body on both sides of the ladder, and only a light
    /// palette shows whether the role picked for it reads as a band there
    /// too; every other grid render is Tokyo Night.
    func testTheGridRendersInALightTheme() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == "catppuccin-latte" })
        let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-latte.png"))
        }
        assertGridSamples(image, theme: theme)

        // The strip is a band, not the body it sits on: sampled inside a
        // thumbnail's strip and inside the same thumbnail's ground.
        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let strip = hex(image, CGPoint(x: thumbnail.midX, y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(strip, theme.palette.chromeRoles.paneBorder.hex, "the strip carries the role it was given")
        XCTAssertNotEqual(strip, theme.palette.chromeRoles.canvas.hex, "and it is not the thumbnail body")
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
        harness.drag.move(to: CGPoint(x: target.midX, y: target.midY))
        await settle(window)
        if let directory {
            try XCTUnwrap(snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-tab.png"))
        }
        window.close()
    }

    /// Moves the live drag onto a card's own empty space, which is its header
    /// row: no thumbnail or tile covers it.
    private func overEmptySpace(of workspace: WorkspaceID, harness: Harness, window: NSWindow) async throws {
        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        harness.drag.move(to: CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        ))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(workspace))
        await settle(window)
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
    /// Three tabs: a resting card still under its visible-tab cap.
    static let herdr = WorkspaceID(rawValue: "w4")
    static let agentsTab = TabID(rawValue: "w1:t1")
    static let migrationTab = TabID(rawValue: "w2:t1")
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
