import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The rt modal's chrome in a dark and a light theme: its title row with and
/// without the service view's back control, its strip in each tone, and the
/// whole modal over a stand-in window whose tab area it dims. The pane's
/// surface is a stand-in that draws only the terminal's ground. PNGs are
/// written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class RtModalChromeRenderTests: XCTestCase {
    private static let themes = [Theme(.tokyoNight), Theme(.tokyoNightDay)]
    /// Where a hosted part's top-left corner sits in its window.
    private static let inset: CGFloat = 10
    private static let defaultsSuite = "flock.render.rt-modal"

    // MARK: - Parts

    func testTheTitleRowDrawsItsTitleAndOnlyTheServiceViewLeadsWithTheBackControl() async throws {
        ChromeType.install()
        for theme in Self.themes {
            for back in [false, true] {
                let row = RtModalTitleRow(
                    theme: theme, title: "runner · ~/src/acme", showsBackToRunner: back, onBack: {}, onClose: {}
                )
                XCTAssertEqual(NSHostingView(rootView: row).fittingSize.height, ChromeMetrics.RtModal.TitleRow.height)
                let window = host(row.frame(width: 480), theme: theme, size: CGSize(width: 500, height: 48))
                await settle(window)
                let image = try snapshot(window)
                try write(image, "rt-modal-title\(back ? "-back" : "")-\(theme.id).png")
                window.close()

                let label = "\(theme.id) back \(back)"
                let palette = theme.palette
                let roles = palette.chromeRoles
                XCTAssertEqual(hex(image, at: point(300, 3)), roles.chrome.hex, "\(label): the row's fill")
                let strong = pixels(in: image) { self.distance($0, roles.textStrong.hex) <= 24 }.count
                XCTAssertGreaterThan(strong, 150, "\(label): the title did not draw in textStrong")
                let accent = pixels(in: image) { self.distance($0, palette.accent.hex) <= 24 }.count
                if back {
                    XCTAssertGreaterThan(accent, 60, "\(label): the back control did not draw in the accent")
                    let rule = pixels(in: image) { $0 == roles.rule.hex }.count
                    XCTAssertGreaterThanOrEqual(rule, 2 * 24, "\(label): no 1x12 divider after the back control")
                } else {
                    XCTAssertEqual(accent, 0, "\(label): accent drawn with no back control")
                }
            }
        }
    }

    func testTheStripDrawsExitedInRedAndFinishedInTextStrongUnderARule() async throws {
        ChromeType.install()
        let strips: [(name: String, strip: RtStrip)] = [("exited", .exited(1)), ("finished", .finished(0))]
        for theme in Self.themes {
            for (name, strip) in strips {
                let view = RtModalStripView(theme: theme, strip: strip)
                XCTAssertEqual(NSHostingView(rootView: view).fittingSize.height, ChromeMetrics.RtModal.Strip.height)
                let window = host(view.frame(width: 480), theme: theme, size: CGSize(width: 500, height: 46))
                await settle(window)
                let image = try snapshot(window)
                try write(image, "rt-modal-strip-\(name)-\(theme.id).png")
                window.close()

                let label = "\(theme.id) \(name)"
                let palette = theme.palette
                let roles = palette.chromeRoles
                XCTAssertEqual(hex(image, at: point(400, 0.5)), roles.rule.hex, "\(label): the rule along the top")
                XCTAssertEqual(hex(image, at: point(400, 4)), roles.chrome.hex, "\(label): the strip's fill")
                let red = pixels(in: image) { self.distance($0, palette.red.hex) <= 24 }.count
                let strong = pixels(in: image) { self.distance($0, roles.textStrong.hex) <= 24 }.count
                if case .exited = strip {
                    XCTAssertGreaterThan(red, 150, "\(label): exited is not red")
                } else {
                    XCTAssertEqual(red, 0, "\(label): finished drew red")
                    XCTAssertGreaterThan(strong, 150, "\(label): finished is not in textStrong")
                }
            }
        }
    }

    // MARK: - The whole modal

    private enum Variant: String, CaseIterable {
        case nav, exited, service
    }

    /// The box is 0.9 of the tab area and centred in it; the backdrop dims
    /// the tab area by the theme's opacity; the pane sits the inset in from
    /// the box's edges under the title row, sized to whole cells; a strip,
    /// when there is one, closes the box under its rule.
    func testTheModalDimsTheTabAreaAndCentresItsBoxAtNineTenths() async throws {
        ChromeType.install()
        for theme in Self.themes {
            for variant in Variant.allCases {
                let window = try await hostModal(theme: theme, variant: variant).window
                defer { window.close() }
                let image = try snapshot(window)
                try write(image, "rt-modal-window-\(variant.rawValue)-\(theme.id).png")

                let label = "\(theme.id) \(variant.rawValue)"
                let palette = theme.palette
                let roles = palette.chromeRoles
                let box = StandIn.box(in: window)
                let opacity = ChromeRoles.isLight(panelBg: palette.panelBg)
                    ? ChromeMetrics.RtModal.lightBackdropOpacity : ChromeMetrics.RtModal.darkBackdropOpacity

                let dimmed = hex(image, at: CGPoint(x: StandIn.size.width - 20, y: StandIn.titleBar + 15))
                XCTAssertLessThanOrEqual(
                    distance(dimmed, dim(roles.tabStripFill.hex, by: opacity)), 2,
                    "\(label): the tab strip under the backdrop reads \(dimmed)"
                )
                XCTAssertEqual(hex(image, at: CGPoint(x: StandIn.rail / 2, y: 300)), roles.chrome.hex, "\(label): the rail is dimmed")

                XCTAssertEqual(hex(image, at: CGPoint(x: box.minX + 0.25, y: box.midY)), roles.paneBorder.hex, "\(label): left edge")
                XCTAssertEqual(hex(image, at: CGPoint(x: box.maxX - 0.75, y: box.midY)), roles.paneBorder.hex, "\(label): right edge")
                XCTAssertEqual(hex(image, at: CGPoint(x: box.midX, y: box.minY + 0.25)), roles.paneBorder.hex, "\(label): top edge")
                XCTAssertEqual(hex(image, at: CGPoint(x: box.midX, y: box.maxY - 0.75)), roles.paneBorder.hex, "\(label): bottom edge")
                XCTAssertNotEqual(hex(image, at: CGPoint(x: box.minX - 0.75, y: box.midY)), roles.paneBorder.hex, "\(label): wider than 0.9")

                let titleRow = ChromeMetrics.RtModal.TitleRow.height
                XCTAssertEqual(hex(image, at: CGPoint(x: box.midX + 100, y: box.minY + 3)), roles.chrome.hex, "\(label): title row")
                XCTAssertEqual(hex(image, at: CGPoint(x: box.midX, y: box.minY + titleRow + 2)), roles.pane.hex, "\(label): pane ground")
                let stripHeight = ChromeMetrics.RtModal.Strip.height
                if variant == .exited {
                    XCTAssertEqual(hex(image, at: CGPoint(x: box.maxX - 40, y: box.maxY - 4)), roles.chrome.hex, "\(label): strip")
                    XCTAssertEqual(
                        hex(image, at: CGPoint(x: box.maxX - 40, y: box.maxY - stripHeight + 0.25)), roles.rule.hex,
                        "\(label): the strip's rule"
                    )
                } else {
                    XCTAssertEqual(hex(image, at: CGPoint(x: box.maxX - 40, y: box.maxY - 4)), roles.pane.hex, "\(label): no strip")
                }

                let surface = try XCTUnwrap(surfaceFrame(in: window), "\(label): no surface in the box")
                let paneInset = ChromeMetrics.RtModal.paneInset
                let area = CGRect(
                    x: box.minX + paneInset, y: box.minY + titleRow + paneInset,
                    width: box.width - 2 * paneInset,
                    height: box.height - titleRow - 2 * paneInset - (variant == .exited ? stripHeight : 0)
                )
                let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuite))
                let cell = TerminalCellMetrics.cell(fontSize: TerminalTextSizeStore(userDefaults: defaults).points, scale: 2)
                XCTAssertEqual(surface.origin, area.origin, "\(label): the surface's origin")
                XCTAssertLessThanOrEqual(surface.width, area.width, "\(label): surface width")
                XCTAssertGreaterThan(surface.width, area.width - cell.width, "\(label): surface width")
                XCTAssertLessThanOrEqual(surface.height, area.height, "\(label): surface height")
                XCTAssertGreaterThan(surface.height, area.height - cell.height, "\(label): surface height")
            }
        }
    }

    /// Only the backdrop closes the modal on a click, and it takes that click
    /// from the terminal beneath it; a click in the box, on its title row or
    /// on its pane, leaves it up.
    func testABackdropClickClosesTheModalAndAClickInTheBoxDoesNot() async throws {
        ChromeType.install()
        let hosted = try await hostModal(theme: Theme(.tokyoNight), variant: .nav)
        let (window, viewModel, probe) = (hosted.window, hosted.viewModel, hosted.probe)
        defer { window.close() }
        let box = StandIn.box(in: window)

        click(window, at: CGPoint(x: box.midX, y: box.minY + 14))
        click(window, at: CGPoint(x: box.midX, y: box.midY))
        await settle(window)
        XCTAssertNotNil(viewModel.rt.modal, "a click in the box closed the modal")

        let overProbe = CGPoint(x: (box.maxX + StandIn.size.width) / 2, y: box.midY)
        click(window, at: overProbe)
        await settle(window)
        XCTAssertNil(viewModel.rt.modal, "a backdrop click left the modal up")
        XCTAssertEqual(probe.clicks, 0, "the terminal under the backdrop took its click")

        click(window, at: overProbe)
        await settle(window)
        XCTAssertEqual(probe.clicks, 1, "the probe under the backdrop cannot take a click at all")
    }

    func testTheCloseControlClosesAndTheBackControlReturnsToTheBoard() async throws {
        ChromeType.install()
        let hosted = try await hostModal(theme: Theme(.tokyoNight), variant: .service)
        let (window, viewModel) = (hosted.window, hosted.viewModel)
        defer { window.close() }
        let box = StandIn.box(in: window)
        let row = ChromeMetrics.RtModal.TitleRow.self
        let y = box.minY + row.height / 2

        click(window, at: CGPoint(x: box.minX + row.horizontalPadding + 12, y: y))
        await settle(window)
        XCTAssertNotNil(viewModel.rt.modal, "back closed the modal")
        XCTAssertNil(viewModel.rt.modal?.serviceTabID, "back left the service on screen")

        click(window, at: CGPoint(x: box.maxX - row.horizontalPadding - row.closeGlyphSize / 2, y: y))
        await settle(window)
        XCTAssertNil(viewModel.rt.modal, "the close control left the modal up")
    }

    /// ⌘W closes; a plain key closes only under a strip; other ⌘ keys pass.
    func testTheModalsKeysCloseItOnCommandWAndUnderAStripOnAnyPlainKey() async throws {
        ChromeType.install()
        let hosted = try await hostModal(theme: Theme(.tokyoNight), variant: .nav)
        let (window, viewModel) = (hosted.window, hosted.viewModel)
        defer { window.close() }
        press(window, "j")
        press(window, "k", command: true)
        await settle(window)
        XCTAssertNotNil(viewModel.rt.modal, "a key other than ⌘W closed a modal with no strip")
        press(window, "w", command: true)
        await settle(window)
        XCTAssertNil(viewModel.rt.modal, "⌘W left the modal up")

        let stripHosted = try await hostModal(theme: Theme(.tokyoNight), variant: .exited)
        let (stripWindow, stripViewModel) = (stripHosted.window, stripHosted.viewModel)
        defer { stripWindow.close() }
        press(stripWindow, "k", command: true)
        await settle(stripWindow)
        XCTAssertNotNil(stripViewModel.rt.modal, "a ⌘ key closed the modal under a strip")
        press(stripWindow, "j")
        await settle(stripWindow)
        XCTAssertNil(stripViewModel.rt.modal, "a plain key left the modal up under a strip")
    }

    /// The modal's terminal re-asserts its claim on the keyboard whenever its
    /// view updates (a new text size here; in the app also a resize or a
    /// first frame). While a rename editor is on screen it must yield,
    /// through a herdr model change and through such an update, and take the
    /// keyboard back once the editor closes.
    func testTheModalsTerminalYieldsTheKeyboardToARenameEditor() async throws {
        ChromeType.install()
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let hosted = try await hostModal(
            theme: Theme(.tokyoNight), variant: .nav, factory: SessionSurfaceFactory(host: host), model: Self.model(revision: 1)
        )
        let (window, viewModel) = (hosted.window, hosted.viewModel)
        defer { window.close() }
        let terminal = try XCTUnwrap(ghosttyView(in: window), "no ghostty surface in the modal")
        XCTAssertTrue(window.firstResponder === terminal, "the modal's terminal does not hold the keyboard")

        viewModel.beginRename(.workspace(Self.workspace))
        await settle(window)
        hosted.editor.armed = true
        XCTAssertTrue(window.makeFirstResponder(hosted.editor), "the stand-in editor would not take the keyboard")
        viewModel.update(model: Self.model(revision: 2), connection: .live)
        await settle(window)
        XCTAssertTrue(window.firstResponder === hosted.editor, "a model change gave a rename editor's keyboard to the modal")
        hosted.textSize.select(.large)
        defer { hosted.textSize.select(.regular) }
        await settle(window)
        XCTAssertTrue(window.firstResponder === hosted.editor, "an update of the modal's terminal took a rename editor's keyboard")

        viewModel.cancelRename()
        await settle(window)
        XCTAssertTrue(window.firstResponder === terminal, "the modal's terminal did not take the keyboard back")
    }

    /// Under a strip a plain key closes the modal, except while a rename
    /// editor is on screen: that key is being typed into the editor.
    func testAPlainKeyUnderAStripPassesWhileARenameEditorIsOpen() async throws {
        ChromeType.install()
        let hosted = try await hostModal(theme: Theme(.tokyoNight), variant: .exited, model: Self.model(revision: 1))
        let (window, viewModel) = (hosted.window, hosted.viewModel)
        defer { window.close() }

        viewModel.beginRename(.workspace(Self.workspace))
        await settle(window)
        press(window, "j")
        await settle(window)
        XCTAssertNotNil(viewModel.rt.modal, "a key typed into a rename editor closed the modal")

        viewModel.cancelRename()
        await settle(window)
        press(window, "j")
        await settle(window)
        XCTAssertNil(viewModel.rt.modal, "a plain key left the modal up under a strip once the editor closed")
    }

    // MARK: - The stand-in window

    /// Laid out as `MainWindow` lays out its own: a title bar, the rail, and
    /// the tab area (a strip over the canvas's two panes) that the modal
    /// covers. Sized as the canvas's reference render is.
    private struct StandIn: View {
        static let size = CGSize(width: 1100, height: 690)
        static let titleBar: CGFloat = 30
        static let rail: CGFloat = 150
        static let tabArea = CGRect(x: rail, y: titleBar, width: size.width - rail, height: size.height - titleBar)
        static let boxFraction: CGFloat = 0.9

        /// `boxFraction` of the tab area, centred, each edge on the window's
        /// device pixels: at 0.9 an edge can fall on a half point.
        static func box(in window: NSWindow) -> CGRect {
            let scale = window.backingScaleFactor
            func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let marginX = tabArea.width * (1 - boxFraction) / 2
            let marginY = tabArea.height * (1 - boxFraction) / 2
            let left = snap(tabArea.minX + marginX)
            let right = snap(tabArea.maxX - marginX)
            let top = snap(tabArea.minY + marginY)
            let bottom = snap(tabArea.maxY - marginY)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }

        let theme: Theme
        let viewModel: SessionViewModel
        let probe: ClickProbeView
        let editor: EditorStandInView

        var body: some View {
            VStack(spacing: 0) {
                theme.chrome.frame(height: Self.titleBar)
                HStack(spacing: 0) {
                    theme.chrome
                        .frame(width: Self.rail)
                        .overlay(alignment: .trailing) { theme.rule.frame(width: 1) }
                        .overlay(alignment: .top) { EditorStandIn(view: editor).frame(height: 24).padding(10) }
                    VStack(spacing: 0) {
                        theme.tabStripFill.frame(height: ChromeMetrics.Strip.height)
                        HStack(spacing: 12) {
                            paneBox { theme.pane }
                            paneBox { ClickProbe(view: probe) }
                        }
                        .padding(6)
                        .background(theme.canvas)
                    }
                    .overlay { RtModalView(theme: theme, viewModel: viewModel) }
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }

        private func paneBox(@ViewBuilder _ content: () -> some View) -> some View {
            content()
                .clipShape(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(theme.paneBorder, lineWidth: 1))
        }
    }

    private struct Hosted {
        let window: NSWindow
        let viewModel: SessionViewModel
        let probe: ClickProbeView
        let editor: EditorStandInView
        let textSize: TerminalTextSizeStore
    }

    /// `model`, when given, carries the pane the item is linked to, so the
    /// coordinator does not take the item for one whose pane has gone.
    private func hostModal(
        theme: Theme, variant: Variant, factory: any GhosttyPaneFactory = GroundSurfaceFactory(), model: SessionModel? = nil
    ) async throws -> Hosted {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuite))
        defaults.removeObject(forKey: TerminalTextSizeStore.defaultsKey)
        let textSize = TerminalTextSizeStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), ghosttyFactory: factory)
        if let model {
            viewModel.update(model: model, connection: .live)
        }
        let home = NSHomeDirectory()
        let item: RtItem
        var serviceTabID: TabID?
        switch variant {
        case .nav:
            item = Self.item(kind: .nav, title: "nav", folder: home + "/src/acme", strip: nil)
        case .exited:
            item = Self.item(kind: .run, title: "pnpm run test", folder: home + "/src/acme/web", strip: .exited(1))
        case .service:
            item = Self.item(kind: .runner, title: "runner", folder: home + "/src/acme", strip: nil)
            serviceTabID = TabID(rawValue: "rt:t2")
        }
        viewModel.rt.items[item.id] = item
        viewModel.rt.modal = RtModal(itemID: item.id, tabID: item.tabID, serviceTabID: serviceTabID)

        let probe = ClickProbeView()
        let editor = EditorStandInView()
        let root = StandIn(theme: theme, viewModel: viewModel, probe: probe, editor: editor)
            .environment(textSize)
            .environment(OptionAsAltStore(userDefaults: defaults))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: StandIn.size), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        return Hosted(window: window, viewModel: viewModel, probe: probe, editor: editor, textSize: textSize)
    }

    private static let workspace = WorkspaceID(rawValue: "w1")

    /// One workspace, one tab, and the pane the modal's item is linked to.
    /// `revision` is there to make a second model that differs from the first.
    private static func model(revision: Int) -> SessionModel {
        let tab = TabID(rawValue: "w1:t1")
        var pane = PaneRecord(
            paneID: PaneID(rawValue: "w1:p1"), workspaceID: workspace, tabID: tab, focused: true, agentStatus: .idle,
            revision: revision, terminalTitleStripped: "zsh", label: nil, cwd: "/private/tmp", scroll: nil
        )
        pane.terminalID = TerminalID(rawValue: "term-1")
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: workspace, focusedTabID: tab, focusedPaneID: pane.paneID,
            workspaces: [
                WorkspaceRecord(workspaceID: workspace, label: "acme", number: 1, activeTabID: tab, agentStatus: .idle),
            ],
            tabs: [TabRecord(tabID: tab, workspaceID: workspace, label: "main", number: 1, paneCount: 1, agentStatus: .idle)],
            panes: [pane], layouts: []
        ))
    }

    private func ghosttyView(in window: NSWindow) -> GhosttySurfaceView? {
        func find(_ view: NSView) -> GhosttySurfaceView? {
            if let surface = view as? GhosttySurfaceView { return surface }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    private static func item(kind: RtKind, title: String, folder: String, strip: RtStrip?) -> RtItem {
        RtItem(
            id: "\(kind.rawValue)-1", kind: kind, linked: TerminalID(rawValue: "term-1"),
            workspaceID: WorkspaceID(rawValue: "rt"), tabID: TabID(rawValue: "rt:t1"),
            firstPaneID: PaneID(rawValue: "rt:p1"), title: title, folder: folder,
            isRunning: strip == nil, strip: strip
        )
    }

    /// The pane's surface as the window holds it, top-left in the window.
    private func surfaceFrame(in window: NSWindow) -> CGRect? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "PlaceholderGhosttyHostView" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let surface = find(root) else { return nil }
        let frame = surface.convert(surface.bounds, to: nil)
        return CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: - Helpers

    private var directory: String? {
        ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: Self.inset + x, y: Self.inset + y)
    }

    /// Hosts `view` at `inset` from the top-left of a borderless window over
    /// the pane's ground, which is what the modal's rows sit against.
    private func host(_ view: some View, theme: Theme, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                theme.pane
                view.padding(.leading, Self.inset).padding(.top, Self.inset)
            }
            .frame(width: size.width, height: size.height)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow, passes: Int = 6) async {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A press and a release at `point`, top-left in the window's content.
    private func click(_ window: NSWindow, at point: CGPoint) {
        let height = window.contentView?.bounds.height ?? 0
        let location = NSPoint(x: point.x, y: height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// Through the application, where local monitors see an event before
    /// any window or menu does.
    private func press(_ window: NSWindow, _ key: String, command: Bool = false) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the declared hexes.
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

    private func write(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let directory else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

    private func pixels(in image: NSBitmapImageRep, where matches: (String) -> Bool) -> [(x: Int, y: Int)] {
        var found: [(x: Int, y: Int)] = []
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where matches(hex(image, pixelX: x, pixelY: y)) {
                found.append((x, y))
            }
        }
        return found
    }

    private func hex(_ image: NSBitmapImageRep, at point: CGPoint, scale: CGFloat = 2) -> String {
        hex(image, pixelX: Int(point.x * scale), pixelY: Int(point.y * scale))
    }

    private func hex(_ image: NSBitmapImageRep, pixelX x: Int, pixelY y: Int) -> String {
        guard let data = image.bitmapData, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private func channels(_ hex: String) -> [Int]? {
        let digits = Array(hex.dropFirst())
        guard digits.count == 6 else { return nil }
        return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
    }

    private func distance(_ lhs: String, _ rhs: String) -> Int {
        guard let left = channels(lhs), let right = channels(rhs) else { return Int.max }
        return zip(left, right).map { abs($0 - $1) }.max() ?? Int.max
    }

    /// `hex` under black at `opacity`.
    private func dim(_ hex: String, by opacity: Double) -> String {
        let dimmed = (channels(hex) ?? [0, 0, 0]).map { Int((Double($0) * (1 - opacity)).rounded()) }
        return String(format: "#%02X%02X%02X", dimmed[0], dimmed[1], dimmed[2])
    }
}

/// A terminal under the backdrop: counts the clicks AppKit hands it.
private final class ClickProbeView: NSView {
    var clicks = 0

    override func mouseDown(with event: NSEvent) {
        clicks += 1
    }
}

private struct ClickProbe: NSViewRepresentable {
    let view: ClickProbeView

    func makeNSView(context: Context) -> ClickProbeView { view }
    func updateNSView(_ nsView: ClickProbeView, context: Context) {}
}

/// Where a rename editor's field would sit: a view that takes the keyboard
/// once a test arms it. An xctest window never becomes key, and in one that
/// holds any view accepting first responder SwiftUI's tap gestures stop
/// firing, which would take the backdrop's click away from every other test.
private final class EditorStandInView: NSView {
    var armed = false
    override var acceptsFirstResponder: Bool { armed }
}

private struct EditorStandIn: NSViewRepresentable {
    let view: EditorStandInView

    func makeNSView(context: Context) -> EditorStandInView { view }
    func updateNSView(_ nsView: EditorStandInView, context: Context) {}
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}

@MainActor
private final class GroundSurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    func resumeScreenActivityReporting() {}
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}

/// A real libghostty surface over `/usr/bin/true`, for the one test that
/// needs the terminal's own claim on the keyboard.
@MainActor
private struct SessionSurfaceFactory: GhosttyPaneFactory {
    let host: GhosttyHost

    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GhosttySessionSurfaceHandle(session: host.makeSession(
            paneID: pane,
            configuration: GhosttySession.Launch(
                commandArgv: ["/usr/bin/true"], themeColors: Theme.tokyoNight.ghosttyThemeColors()
            )
        ))
    }
}
