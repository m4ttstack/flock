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

    func testAThumbnailsHoverOutlineGivesWayToALiveDrag() {
        XCTAssertEqual(ThumbnailHover.outline(theme: theme, isHovering: false, dragInFlight: false), .clear)
        XCTAssertNotEqual(ThumbnailHover.outline(theme: theme, isHovering: true, dragInFlight: false), .clear)
        XCTAssertEqual(ThumbnailHover.outline(theme: theme, isHovering: true, dragInFlight: true), .clear)
    }
}

/// A mission card (plain and blocked), a dormant chip, a dormant row and the
/// mode toggle at rest, hovered and pressed, in a dark and a light theme.
/// PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class GridControlHoverRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 1180, height: 330)
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
            XCTAssertEqual(grounds[0], theme.palette.chromeRoles.chrome.hex, "\(id): a resting card is on chrome")
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
        func card(_ status: AgentStatus, _ index: Int) -> some View {
            MissionCardView(
                theme: theme,
                card: MissionCard(
                    paneID: Self.pane(status, index), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
                    workspaceName: "acme", tabTitle: "api", title: "Refactor the request pipeline",
                    status: status, since: now.addingTimeInterval(-300), folder: "/tmp/acme"
                ),
                showsWorkspace: true, identity: nil, repoBranch: RepoBranch(repo: "acme", branch: "main"),
                segments: [], now: now, isSelected: false, isCooling: false, forced: Self.states[index].1, activate: {}
            )
            .frame(width: Self.column - 30)
        }
        return HStack(alignment: .top, spacing: 30) {
            ForEach(0..<Self.states.count, id: \.self) { index in
                let interaction = Self.states[index].1
                VStack(alignment: .leading, spacing: 20) {
                    card(.working, index)
                    card(.blocked, index)
                    HStack(spacing: 12) {
                        DormantChipButton(theme: theme, status: .idle, label: "acme-docs", forced: interaction, action: {})
                        HStack(spacing: 2) {
                            ModeToggleSegment(theme: theme, title: "Mission control", isOn: true, forced: interaction, action: {})
                            ModeToggleSegment(theme: theme, title: "Arrange", isOn: false, forced: interaction, action: {})
                        }
                        .padding(2)
                        .background(theme.tabRest, in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.toggleCornerRadius))
                    }
                    GridControlButton(
                        theme: theme, shape: AnyShape(RoundedRectangle(cornerRadius: ChromeMetrics.Rail.headingButtonCornerRadius)),
                        restForeground: theme.textLabel, forced: interaction, action: {}
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("3 dormant").font(ChromeType.missionGroupLabel)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, ChromeMetrics.MissionControl.dormantRowVerticalPadding)
                        .padding(.horizontal, ChromeMetrics.MissionControl.dormantRowHorizontalPadding)
                    }
                    .frame(width: Self.column - 30)
                }
                .frame(width: Self.column - 30, alignment: .leading)
            }
        }
        .padding(16)
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
