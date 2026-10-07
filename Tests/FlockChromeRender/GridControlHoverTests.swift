import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Rest, hover and press for the All Workspaces view's controls, asserted on
/// the resolved appearance since a test cannot move a pointer or build a
/// `ButtonStyle.Configuration`.
@MainActor
final class GridControlAppearanceTests: XCTestCase {
    private let theme = Theme(.tokyoNight)

    private func resolve(_ interaction: ControlInteraction) -> GridControlAppearance {
        GridControlAppearance.resolve(
            theme: theme, restForeground: theme.textLabel,
            isHovering: interaction.isHovering, isPressed: interaction.isPressed
        )
    }

    func testRestHoverAndPressAreThreeDifferentAppearances() {
        let rest = resolve(.rest), hover = resolve(.hover), pressed = resolve(.pressed)
        XCTAssertNotEqual(rest, hover, "hover must change the control")
        XCTAssertNotEqual(hover, pressed, "a press must change a hovered control")
        XCTAssertNotEqual(rest.lift, hover.lift, "hover lifts the ground")
        XCTAssertNotEqual(rest.foreground, hover.foreground, "hover strengthens the label")
    }

    func testAPressReadsStrongerThanAHover() {
        XCTAssertEqual(resolve(.rest).pressWash, 0)
        XCTAssertEqual(resolve(.hover).pressWash, 0)
        XCTAssertGreaterThan(resolve(.pressed).pressWash, 0)
        XCTAssertEqual(resolve(.pressed).lift, resolve(.hover).lift, "a press keeps the hover's lift under its wash")
    }

    func testACardsPressIsQuieterThanAControlsButStillThere() {
        let card = GridControlAppearance.resolve(
            theme: theme, restForeground: theme.textStrong, pressAccent: ChromeMetrics.MissionControl.cardPressedAccent,
            isHovering: true, isPressed: true
        )
        XCTAssertGreaterThan(card.pressWash, 0)
        XCTAssertLessThan(card.pressWash, resolve(.pressed).pressWash)
    }

    func testAPressWithoutHoverStillLightsTheControl() {
        let cold = resolve(ControlInteraction(isHovering: false, isPressed: true))
        XCTAssertEqual(cold.lift, resolve(.hover).lift)
        XCTAssertGreaterThan(cold.pressWash, 0)
    }

    private let pane = PaneID(rawValue: "w1:t1:p1")
    private let other = PaneID(rawValue: "w1:t1:p2")

    private func part(_ part: ThumbnailPart, hovered: ThumbnailPart?, pressed: ThumbnailPart? = nil, dragging: Bool = false) -> ControlInteraction {
        ThumbnailPart.interaction(of: part, hovered: hovered, pressed: pressed, dragInFlight: dragging)
    }

    func testOverAPaneOnlyThatPaneLightsNotTheTabOrItsNeighbour() {
        XCTAssertEqual(part(.pane(pane), hovered: .pane(pane)), .hover)
        XCTAssertEqual(part(.tab, hovered: .pane(pane)), .rest, "a pane under the pointer must not read as the tab")
        XCTAssertEqual(part(.pane(other), hovered: .pane(pane)), .rest)
        XCTAssertEqual(ThumbnailPart.thumbnailOutline(theme: theme, tab: part(.tab, hovered: .pane(pane))), .clear)
    }

    func testOverTheHandleTheTabLightsAndNoPaneDoes() {
        XCTAssertEqual(part(.tab, hovered: .tab), .hover)
        XCTAssertEqual(part(.pane(pane), hovered: .tab), .rest)
        XCTAssertNotEqual(ThumbnailPart.thumbnailOutline(theme: theme, tab: part(.tab, hovered: .tab)), .clear)
    }

    func testAPressLightsThePartItBeganOn() {
        XCTAssertEqual(part(.pane(pane), hovered: .pane(pane), pressed: .pane(pane)), .pressed)
        XCTAssertFalse(part(.tab, hovered: .pane(pane), pressed: .pane(pane)).isPressed)
    }

    func testNothingInAThumbnailLightsWhileADragIsLive() {
        XCTAssertEqual(part(.tab, hovered: .tab, pressed: .tab, dragging: true), .rest)
        XCTAssertEqual(part(.pane(pane), hovered: .pane(pane), dragging: true), .rest)
    }

    func testAPaneHoverRingNeverReplacesTheBlockedOrPreviewedOutline() {
        XCTAssertEqual(ThumbnailPart.paneOutline(theme: theme, status: .blocked, isSelected: false, pane: .hover), theme.red)
        XCTAssertEqual(ThumbnailPart.paneOutline(theme: theme, status: .idle, isSelected: true, pane: .hover), theme.accent)
        XCTAssertEqual(ThumbnailPart.paneOutline(theme: theme, status: .idle, isSelected: false, pane: .rest), theme.rule)
        XCTAssertNotEqual(ThumbnailPart.paneOutline(theme: theme, status: .idle, isSelected: false, pane: .hover), theme.rule)
    }
}

/// A mission card (plain and blocked), two title bar view tabs and At rest's
/// Older disclosure at rest, hovered and pressed, in a dark and a light theme.
/// PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class GridControlHoverRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 1180, height: 590)
    private static let column: CGFloat = 380
    private static let states: [(String, ControlInteraction)] = [("rest", .rest), ("hover", .hover), ("pressed", .pressed)]

    private static func pane(_ status: AgentStatus, _ index: Int) -> PaneID {
        PaneID(rawValue: "w1:\(status.rawValue)\(index)")
    }

    func testHoverAndPressRenderInADarkAndALightTheme() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let window = host(sheet(theme), theme: theme)
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("grid-controls-hover-\(scheme)-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }

            // Inside each plain card's top padding, clear of its text: the
            // ground at rest, hovered and pressed must be three colours.
            let grounds = try (0..<3).map { index in
                let frame = try XCTUnwrap(MissionCardFrames.shared.frames[Self.pane(.working, index)])
                return hex(image, CGPoint(x: frame.maxX - 10, y: frame.minY + 5))
            }
            XCTAssertEqual(grounds[0], theme.palette.chromeRoles.chrome.hex, "\(id): a resting card sits on chrome inside its group")
            XCTAssertEqual(Set(grounds).count, 3, "\(id): rest, hover and press grounds \(grounds) must differ")
            for index in 0..<3 {
                let frame = try XCTUnwrap(MissionCardFrames.shared.frames[Self.pane(.blocked, index)])
                XCTAssertEqual(
                    hex(image, CGPoint(x: frame.minX + 0.75, y: frame.midY)), theme.palette.red.hex,
                    "\(id): \(Self.states[index].0) hides the blocked outline"
                )
            }
        }
    }

    private func sheet(_ theme: Theme) -> some View {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func card(_ status: AgentStatus, _ index: Int, renaming: Bool = false) -> some View {
            MissionCardView(
                theme: theme,
                card: MissionCard(
                    paneID: Self.pane(status, index), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
                    workspaceName: "acme", tabTitle: "api", title: "Refactor the request pipeline",
                    status: status, since: now.addingTimeInterval(-300), folder: "/tmp/acme"
                ),
                place: "acme @ main",
                segments: [], now: now, isSelected: false, isCooling: false, forced: Self.states[index].1,
                rename: renaming ? PaneRename(initialText: "Refactor the request pipeline", commit: { _ in }, cancel: {}) : nil,
                activate: {}
            )
            .frame(width: Self.column - 30)
        }
        return HStack(alignment: .top, spacing: 30) {
            ForEach(0..<Self.states.count, id: \.self) { index in
                let interaction = Self.states[index].1
                VStack(alignment: .leading, spacing: 20) {
                    card(.working, index)
                    card(.blocked, index)
                    HStack(spacing: 0) {
                        ViewTabButton(theme: theme, tab: .overview, isSelected: false, badge: 3, forced: interaction, action: {})
                        ViewTabButton(theme: theme, tab: .arrange, isSelected: true, forced: interaction, action: {})
                    }
                    .frame(height: ChromeMetrics.TitleBar.height)
                    .fixedSize()
                    .background(theme.chrome)
                    RestSectionLabel(
                        theme: theme,
                        section: MissionRestSection(age: .older, groups: [], count: 12, isCollapsible: true, isCollapsed: true),
                        forced: interaction, toggle: {}
                    )
                    .padding(.leading, ChromeMetrics.MissionControl.restDisclosureHorizontalPadding)
                    .frame(width: Self.column - 30)
                    HStack(alignment: .top, spacing: 12) {
                        Self.thumbnail(theme, tab: interaction, pane: .rest)
                        Self.thumbnail(theme, tab: .rest, pane: interaction)
                    }
                    if index == 0 { card(.idle, 0, renaming: true) }
                }
                .frame(width: Self.column - 30, alignment: .leading)
            }
        }
        .padding(16)
    }

    /// An Arrange thumbnail drawn from its parts: the handle in `tab`'s state
    /// over two mini panes, the first in `pane`'s.
    private static func thumbnail(_ theme: Theme, tab: ControlInteraction, pane: ControlInteraction) -> some View {
        VStack(spacing: 0) {
            TabHandleStrip(theme: theme, title: "api", status: .working, isFocusedTab: false, interaction: tab)
            HStack(spacing: ChromeMetrics.Grid.miniPaneGap) {
                MiniPane(theme: theme, title: "claude", status: .working, interaction: pane)
                MiniPane(theme: theme, title: "zsh", status: .idle)
            }
            .padding(ChromeMetrics.Grid.thumbnailPadding)
        }
        .frame(width: 160, height: 90)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeRadius.surface)
                .strokeBorder(ThumbnailPart.thumbnailOutline(theme: theme, tab: tab), lineWidth: ChromeMetrics.ruleWidth)
        )
    }

    private func host(_ view: some View, theme: Theme) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                theme.pane
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
