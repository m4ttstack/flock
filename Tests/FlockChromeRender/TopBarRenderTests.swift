import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The title bar carrying three top-bar workspaces: `dash` live and working,
/// `logs` empty, `board` live with its overlay open. Drawn icon only, with
/// names, and named in a window too narrow for names, in a dark and a light
/// theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class TopBarRenderTests: XCTestCase {
    private static let height: CGFloat = 38
    private static let scale: CGFloat = 2
    private static let main = WorkspaceID(rawValue: "w0")
    private static let dash = WorkspaceID(rawValue: "w1")
    private static let logs = WorkspaceID(rawValue: "w2")
    private static let board = WorkspaceID(rawValue: "w3")

    private struct Hosted {
        let window: NSWindow
        let pins: [String: PinID]
        let drag: DragCoordinator
    }

    private static let names = ["dash", "logs", "board"]

    /// The icon's box inside a button: after the leading padding, centred.
    private static func iconBox(in button: CGRect) -> CGRect {
        let icon = ChromeMetrics.TitleBar.topBarIcon
        return CGRect(x: button.minX + ChromeMetrics.TitleBar.topBarButtonPadding, y: button.midY - icon / 2, width: icon, height: icon)
    }

    func testButtonsDrawIconOnlyWithNamesAndFallBackWhenNarrow() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let metrics = ChromeMetrics.TitleBar.self
        let iconButtonWidth = 2 * metrics.topBarButtonPadding + metrics.topBarIcon
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let roles = theme.palette.chromeRoles
            let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
            let openWash = isLight
                ? roles.chrome.mixed(with: RGB(0, 0, 0), amount: ChromeMetrics.MenuBarWash.lightOpen)
                : roles.chrome.mixed(with: RGB(255, 255, 255), amount: ChromeMetrics.MenuBarWash.darkOpen)
            let dimmed = roles.textStrong.mixed(with: roles.chrome, amount: 1 - metrics.topBarEmptyOpacity)
            let working = theme.palette.yellow
            for (name, width, label) in [("icons", 1100.0, TopBarLabel.iconOnly), ("names", 1100.0, .iconAndName), ("narrow", 540.0, .iconAndName)] {
                let hosted = try await host(theme, width: width, label: label)
                defer { hosted.window.close() }
                let image = try snapshot(hosted.window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("top-bar-\(name)-\(scheme).png"))
                }
                let message = "\(name) \(scheme)"
                let buttons = hosted.drag.topBarFrames.map(\.frame)
                XCTAssertEqual(buttons.count, 3, message)
                guard buttons.count == 3 else { continue }
                let button = { (pin: String) in buttons[Self.names.firstIndex(of: pin)!] }
                for frame in buttons {
                    XCTAssertEqual(frame.height, metrics.topBarButtonHeight, accuracy: 0.5, "\(message): \(frame)")
                    XCTAssertEqual(frame.midY, metrics.height / 2, accuracy: 0.5, "\(message): centred in the bar \(frame)")
                }
                for (a, b) in zip(buttons, buttons.dropFirst()) {
                    XCTAssertEqual(b.minX - a.maxX, metrics.topBarButtonGap, accuracy: 0.5, "\(message): the gap")
                }
                // A button is wider than its icon and padding exactly when it carries a name.
                XCTAssertEqual(buttons.allSatisfy { $0.width > iconButtonWidth + 1 }, name == "names", "\(message): \(buttons)")
                if name != "names" {
                    XCTAssertTrue(buttons.allSatisfy { abs($0.width - iconButtonWidth) < 0.5 }, "\(message): \(buttons)")
                }
                XCTAssertEqual(
                    try XCTUnwrap(buttons.last).maxX, width - metrics.topBarEdgeInset, accuracy: 0.5, "\(message): inset from the edge"
                )

                // Status is the icon's colour: dash works, board is idle.
                let dashInk = count(working, tolerance: 16, in: image, within: Self.iconBox(in: button("dash")))
                XCTAssertGreaterThan(dashInk, 60, "\(message): the working icon is not drawn in the working colour")
                XCTAssertEqual(
                    count(working, tolerance: 16, in: image, within: button("board")), 0,
                    "\(message): the idle icon is tinted, or a dot remains"
                )
                XCTAssertGreaterThan(
                    count(roles.textStrong, tolerance: 16, in: image, within: Self.iconBox(in: button("board"))), 30,
                    "\(message): the idle icon is not textStrong"
                )
                let logsIcon = Self.iconBox(in: button("logs"))
                XCTAssertGreaterThan(count(dimmed, tolerance: 12, in: image, within: logsIcon), 30, "\(message): the empty icon is not dimmed")
                XCTAssertEqual(count(roles.textStrong, tolerance: 16, in: image, within: logsIcon), 0, "\(message): the empty icon is full strength")

                // Grounds, sampled in the leading padding beside each icon.
                let ground = { (pin: String) in CGPoint(x: button(pin).minX + 3, y: button(pin).midY) }
                let open = try XCTUnwrap(sample(image, ground("board")))
                XCTAssertLessThanOrEqual(distance(open, openWash), 2, "\(message): the open button drew \(open.hex), not \(openWash.hex)")
                for pin in ["dash", "logs"] {
                    let rest = try XCTUnwrap(sample(image, ground(pin)))
                    XCTAssertLessThanOrEqual(distance(rest, roles.chrome), 2, "\(message): \(pin) drew a ground at rest: \(rest.hex)")
                }
            }
        }
    }

    /// `logs` picked up and carried over `dash`'s leading half: the gap opens
    /// before `dash`, which slides along by `logs`' advance, `board` stays, and
    /// `logs` itself is left ghosted.
    func testACellDraggedAlongTheBarOpensAGapThere() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let hosted = try await host(theme, width: 1100, label: .iconAndName)
            defer { hosted.window.close() }
            let drag = hosted.drag
            drag.stripWorkspace = Self.main
            let frames = drag.topBarFrames
            XCTAssertEqual(frames.map(\.id), try Self.names.map { try XCTUnwrap(hosted.pins[$0]) }, scheme)
            guard frames.count == 3 else { continue }
            let dash = frames[0].frame, logs = frames[1].frame
            XCTAssertNotNil(drag.topBarFrame, scheme)

            drag.beginIfIdle(
                .pin(try XCTUnwrap(hosted.pins["logs"])),
                ghost: DragCoordinator.Ghost(title: "logs", symbol: "square.grid.2x2", originSize: logs.size),
                at: CGPoint(x: logs.midX, y: logs.midY)
            )
            drag.move(to: CGPoint(x: dash.minX + 4, y: dash.midY))
            XCTAssertEqual(drag.target, .topBar(insertIndex: 0), scheme)
            XCTAssertEqual(drag.topBarDisplacement(at: 0), logs.width + ChromeMetrics.TitleBar.topBarButtonGap, accuracy: 0.5, "\(scheme): dash slides along by logs and its gap")
            XCTAssertEqual(drag.topBarDisplacement(at: 2), 0, "\(scheme): board stays")
            let bar = try XCTUnwrap(drag.insertionMark?.bar, "\(scheme): the insertion bar shows in the title bar")
            XCTAssertEqual(bar.midX, dash.minX, accuracy: 2, "\(scheme): the bar sits before dash: \(bar)")

            for _ in 0..<6 {
                hosted.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(drag.topBarFrames.map(\.frame), frames.map(\.frame), "\(scheme): resting frames hold under the slide")
            if let directory {
                try XCTUnwrap(try snapshot(hosted.window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("top-bar-drag-\(scheme).png"))
            }
            drag.release()
        }
    }

    // MARK: - The overlay

    private static let overlaySize = CGSize(width: 1100, height: 700)
    private nonisolated static let left = PaneID(rawValue: "w1:p1")
    private nonisolated static let right = PaneID(rawValue: "w1:p2")

    private enum OverlayCase: String, CaseIterable {
        case oneSmall = "one-small", oneLarge = "one-large", splitMedium = "split-medium", tabsMedium = "tabs-medium"

        var size: ModalSize {
            switch self {
            case .oneSmall: .small
            case .oneLarge: .large
            case .splitMedium, .tabsMedium: .medium
            }
        }

        var panes: [PaneID] { self == .splitMedium ? [left, right] : [left] }
    }

    /// The overlay is the shared modal: its card is the size's box over the
    /// area it is mounted on, its title row names the pin, and each of the
    /// tab's panes sits in its layout box: one pane fills the content area as
    /// the rt modal's does, a split leaves one gutter between two outlined
    /// boxes, the focused one in the accent.
    func testTheOverlayIsTheSharedModalHoldingTheTabsPanes() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let roles = theme.palette.chromeRoles
            for overlay in OverlayCase.allCases {
                let (window, viewModel) = try await hostOverlay(theme, overlay)
                defer { window.close() }
                let image = try snapshot(window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("top-bar-overlay-\(overlay.rawValue)-\(scheme).png")
                    )
                }
                let message = "\(overlay.rawValue) \(scheme)"
                let scale = window.backingScaleFactor
                let box = ChromeModal<EmptyView, EmptyView, EmptyView>.boxFrame(
                    in: Self.overlaySize, origin: .zero, scale: scale, fraction: ChromeMetrics.Modal.sizeFraction(overlay.size)
                )
                for (edge, point) in [
                    ("left", CGPoint(x: box.minX + 0.25, y: box.midY)), ("right", CGPoint(x: box.maxX - 0.75, y: box.midY)),
                    ("top", CGPoint(x: box.midX, y: box.minY + 0.25)), ("bottom", CGPoint(x: box.midX, y: box.maxY - 0.75)),
                ] {
                    let ink = try XCTUnwrap(sample(image, point))
                    XCTAssertLessThanOrEqual(distance(ink, roles.paneBorder), 2, "\(message): the card's \(edge) edge drew \(ink.hex)")
                }
                let outside = try XCTUnwrap(sample(image, CGPoint(x: box.minX - 1, y: box.midY)))
                XCTAssertGreaterThan(distance(outside, roles.paneBorder), 2, "\(message): the card is wider than \(overlay.size)")

                let titleRow = ChromeMetrics.Modal.TitleRow.height
                let title = CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: titleRow)
                XCTAssertGreaterThan(count(roles.textStrong, in: image, within: title), 100, "\(message): no pin name in the title row")
                let note = CGRect(x: box.minX + 140, y: box.minY, width: box.width / 2 - 140, height: titleRow)
                let noted = count(roles.textLabel, in: image, within: note)
                if overlay == .tabsMedium {
                    XCTAssertGreaterThan(noted, 40, "\(message): no note for a workspace past one tab")
                } else {
                    XCTAssertEqual(noted, 0, "\(message): a note for a one-tab workspace")
                }

                let inset = ChromeMetrics.Modal.paneInset
                let area = CGRect(
                    x: box.minX + inset, y: box.minY + titleRow + inset,
                    width: box.width - 2 * inset, height: box.height - titleRow - 2 * inset
                )
                let layout = try XCTUnwrap(viewModel.userModel?.layouts[TabID(rawValue: "w1:t1")])
                let boxes = TopBarOverlayCanvas.geometry(layout: layout, exported: nil, area: area.size, scale: scale)
                    .mapValues { $0.offsetBy(dx: area.minX, dy: area.minY) }
                XCTAssertEqual(Set(boxes.keys), Set(overlay.panes), message)
                let surfaces = surfaceFrames(in: window).sorted { $0.minX < $1.minX }
                XCTAssertEqual(surfaces.count, overlay.panes.count, "\(message): surfaces on screen")
                if overlay.panes.count == 1 {
                    XCTAssertEqual(boxes[Self.left], area, "\(message): one pane's box is the content area")
                    XCTAssertEqual(surfaces.first?.origin, area.origin, "\(message): the surface's origin")
                } else {
                    let left = try XCTUnwrap(boxes[Self.left]), right = try XCTUnwrap(boxes[Self.right])
                    XCTAssertEqual(left.minX, area.minX, message)
                    XCTAssertEqual(right.maxX, area.maxX, message)
                    XCTAssertEqual(right.minX - left.maxX, DividerBand.gutter, "\(message): the gutter")
                    XCTAssertEqual(left.height, area.height, message)
                    let outline = TopBarOverlayCanvas.outlineInset
                    XCTAssertEqual(
                        surfaces.map(\.origin), [left, right].map { CGPoint(x: $0.minX + outline, y: $0.minY + outline) },
                        "\(message): each surface inside its outline"
                    )
                    let focused = try XCTUnwrap(sample(image, CGPoint(x: left.minX + 0.5, y: left.midY)))
                    XCTAssertLessThanOrEqual(distance(focused, roles.accent), 3, "\(message): herdr's focused pane drew \(focused.hex)")
                    let other = try XCTUnwrap(sample(image, CGPoint(x: right.maxX - 0.75, y: right.midY)))
                    XCTAssertLessThanOrEqual(distance(other, roles.paneBorder), 3, "\(message): the other pane drew \(other.hex)")
                }
            }
        }
    }

    private func hostOverlay(_ theme: Theme, _ overlay: OverlayCase) async throws -> (NSWindow, SessionViewModel) {
        let suite = "TopBarRenderTests.overlay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(
            client: OfflineClient(), ghosttyFactory: OverlaySurfaceFactory(), pinnedWorkspaceDefaults: nil, identity: identity
        )
        viewModel.update(model: overlayModel(overlay, tabs: 1), connection: .live)
        viewModel.moveToTopBar(workspace: Self.dash, at: nil)
        if overlay == .tabsMedium {
            viewModel.update(model: overlayModel(overlay, tabs: 2), connection: .live)
        }
        let pin = try XCTUnwrap(viewModel.pins.pins(in: .topBar).first)
        identity.setOverride("server.rack", for: pin.identityKey)
        let sizes = TopBarOverlaySizeStore(userDefaults: defaults)
        sizes.select(overlay.size, for: pin.id)
        await viewModel.toggleTopBar(pin.id)
        XCTAssertEqual(viewModel.topBarOverlay.openPin, pin.id)

        let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
        await board.refresh()
        let root = ZStack {
            theme.canvas
            TopBarWorkspaceOverlay(theme: theme, viewModel: viewModel)
        }
        .frame(width: Self.overlaySize.width, height: Self.overlaySize.height)
        .environment(identity)
        .environment(board)
        .environment(sizes)
        .environment(TerminalTextSizeStore(userDefaults: defaults))
        .environment(OptionAsAltStore(userDefaults: defaults))
        .environment(CommandPaletteState())

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.overlaySize), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return (window, viewModel)
    }

    /// `main`, and `dash` holding the overlay's panes side by side in its
    /// first tab, herdr's focus on the left one.
    private func overlayModel(_ overlay: OverlayCase, tabs: Int) -> SessionModel {
        let tab = TabID(rawValue: "w1:t1")
        let mainTab = TabID(rawValue: "w0:t1")
        let panes = overlay.panes
        let width = 80 / panes.count
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: Self.main, focusedTabID: mainTab, focusedPaneID: nil,
            workspaces: [
                WorkspaceRecord(workspaceID: Self.main, label: "main", number: 1, activeTabID: mainTab, agentStatus: .idle),
                WorkspaceRecord(workspaceID: Self.dash, label: "dash", number: 2, activeTabID: tab, agentStatus: .idle),
            ],
            tabs: [TabRecord(tabID: mainTab, workspaceID: Self.main, label: "first", number: 1, paneCount: 1, agentStatus: .idle)]
                + (1...tabs).map { n in
                    TabRecord(
                        tabID: TabID(rawValue: "w1:t\(n)"), workspaceID: Self.dash, label: "first", number: n,
                        paneCount: n == 1 ? panes.count : 1, agentStatus: .idle
                    )
                },
            panes: panes.map { pane in
                PaneRecord(
                    paneID: pane, workspaceID: Self.dash, tabID: tab, focused: pane == Self.left, agentStatus: .idle,
                    revision: 0, terminalTitleStripped: "zsh", label: nil, cwd: "/acme", scroll: nil
                )
            },
            layouts: [
                LayoutSnapshot(
                    workspaceID: Self.dash, tabID: tab, zoomed: false, area: CellRect(x: 0, y: 0, width: 80, height: 24),
                    focusedPaneID: Self.left,
                    panes: panes.enumerated().map { index, pane in
                        PaneRect(paneID: pane, focused: pane == Self.left, rect: CellRect(x: index * width, y: 0, width: width, height: 24))
                    },
                    splits: []
                ),
            ]
        ))
    }

    /// Every pane's surface as the window holds it, top-left in the window.
    private func surfaceFrames(in window: NSWindow) -> [CGRect] {
        guard let root = window.contentView else { return [] }
        func find(_ view: NSView) -> [NSView] {
            if String(describing: type(of: view)) == "PlaceholderGhosttyHostView" { return [view] }
            return view.subviews.flatMap(find)
        }
        return find(root).map { surface in
            let frame = surface.convert(surface.bounds, to: nil)
            return CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    /// Pixels within `tolerance` of `color` on every channel in `rect`, top
    /// left in the window.
    private func count(_ color: RGB, tolerance: Int = 24, in image: NSBitmapImageRep, within rect: CGRect) -> Int {
        var found = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 1 / Self.scale) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1 / Self.scale) {
                guard let ink = sample(image, CGPoint(x: x, y: y)) else { continue }
                if abs(ink.red - color.red) <= tolerance, abs(ink.green - color.green) <= tolerance,
                   abs(ink.blue - color.blue) <= tolerance { found += 1 }
            }
        }
        return found
    }

    private func host(_ theme: Theme, width: CGFloat, label: TopBarLabel) async throws -> Hosted {
        let suite = "TopBarRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        let all = [Self.main, Self.dash, Self.logs, Self.board]
        viewModel.update(model: model(all), connection: .live)
        for workspace in [Self.dash, Self.logs, Self.board] {
            viewModel.moveToTopBar(workspace: workspace, at: nil)
        }
        viewModel.update(model: model(all.filter { $0 != Self.logs }), connection: .live)
        var pins: [String: PinID] = [:]
        for (name, symbol) in [("dash", "server.rack"), ("logs", "cylinder.fill"), ("board", "square.stack.3d.up.fill")] {
            let pin = try XCTUnwrap(viewModel.pins.pins.first { $0.name == name }, name)
            XCTAssertEqual(pin.placement, .topBar, name)
            identity.setOverride(symbol, for: pin.identityKey)
            pins[name] = pin.id
        }
        XCTAssertNil(viewModel.pins.pin(try XCTUnwrap(pins["logs"]))?.workspace, "logs' pin is empty")
        await viewModel.toggleTopBar(try XCTUnwrap(pins["board"]))
        XCTAssertEqual(viewModel.topBarOverlay.openPin, pins["board"])

        let labels = TopBarLabelStore(userDefaults: defaults)
        labels.select(label)
        let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
        await board.refresh()
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { subject, target in await viewModel.perform(subject: subject, target: target) },
            reveal: { _ in }
        )
        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let root = VStack(spacing: 0) {
            TitleBar(theme: theme, sessionLabel: "render", connectionState: .live, isDevBuild: false, viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Self.height)
        .background(theme.chrome)
        .overlay { DragLayer() }
        .environment(themeStore)
        .environment(drag)
        .environment(AllWorkspacesModeStore(userDefaults: defaults))
        .environment(identity)
        .environment(board)
        .environment(labels)
        .environment(TopBarOverlaySizeStore(userDefaults: defaults))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return Hosted(window: window, pins: pins, drag: drag)
    }

    private func model(_ ids: [WorkspaceID]) -> SessionModel {
        let labels = [Self.main: "main", Self.dash: "dash", Self.logs: "logs", Self.board: "board"]
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: Self.main, focusedTabID: nil, focusedPaneID: nil,
            workspaces: ids.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: labels[id] ?? id.rawValue, number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: id == Self.dash ? .working : .idle
                )
            },
            tabs: ids.map { id in
                TabRecord(
                    tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "first",
                    number: 1, paneCount: 1, agentStatus: id == Self.dash ? .working : .idle
                )
            },
            panes: [],
            layouts: []
        ))
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

@MainActor
private final class OverlaySurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    func resumeScreenActivityReporting() {}
    var hasFirstFrame: Bool { true }
    var hasClaimedMouse: Bool { false }
    var programHasMouse: Bool { false }
}

@MainActor
private struct OverlaySurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        OverlaySurface()
    }
}
