import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The profile picker at the top of the rail: Default current, then acme-mini
/// current while connecting, up and unreachable, then acme-mini with a long
/// label on the narrowest rail; and the open list on its own, since a
/// popover's window does not render offscreen. Dark and light. PNGs are
/// written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ProfilePickerRenderTests: XCTestCase {
    private static let railHeight: CGFloat = 170
    private static let gap: CGFloat = 16
    private static let scale: CGFloat = 2
    private static let mini = HerdrMachine(
        id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default"
    )
    private static let longMini = HerdrMachine(
        id: "fedcba9876543210fedcba9876543210", label: "acme-mini-build-host", target: "acme-mini-build-host", session: "default"
    )

    private struct Column {
        let width: CGFloat
        let current: String
        let dot: ProfileConnectionDot?
    }

    private static let columns: [Column] = [
        Column(width: RailWidth.default, current: FlockProfile.defaultID, dot: nil),
        Column(width: RailWidth.default, current: "machine.\(mini.id)", dot: .attention),
        Column(width: RailWidth.default, current: "machine.\(mini.id)", dot: .live),
        Column(width: RailWidth.default, current: "machine.\(mini.id)", dot: .attention),
        Column(width: RailWidth.minimum, current: "machine.\(longMini.id)", dot: .live),
    ]

    private struct Probe: View {
        let theme: Theme
        let viewModel: SessionViewModel
        let picker: ProfilePickerContext
        let dot: ProfileConnectionDot?
        let width: CGFloat
        let defaults: UserDefaults
        let identity: WorkspaceIdentityStore
        let themeStore: ThemeStore
        @State private var drag: DragCoordinator
        @State private var railWidth: RailWidthStore

        init(
            theme: Theme, viewModel: SessionViewModel, picker: ProfilePickerContext, dot: ProfileConnectionDot?,
            width: CGFloat, defaults: UserDefaults, identity: WorkspaceIdentityStore, themeStore: ThemeStore
        ) {
            self.theme = theme
            self.viewModel = viewModel
            self.picker = picker
            self.dot = dot
            self.width = width
            self.defaults = defaults
            self.identity = identity
            self.themeStore = themeStore
            let toasts = ToastCenter()
            _drag = State(initialValue: DragCoordinator(toasts: toasts, rearrangeMode: RearrangeMode(), commit: { _, _ in .noOp }, reveal: { _ in }))
            let store = RailWidthStore(userDefaults: UserDefaults(suiteName: "ProfilePickerRenderTests.width.\(UUID().uuidString)")!)
            store.released(at: width)
            _railWidth = State(initialValue: store)
        }

        var body: some View {
            WorkspaceRail(theme: theme, viewModel: viewModel, onSelect: { _ in }, profileDot: dot)
                .environment(themeStore)
                .environment(drag)
                .environment(railWidth)
                .environment(SectionCollapseStore(userDefaults: defaults))
                .environment(BoardStore(sources: .unconfigured, userDefaults: defaults))
                .environment(HerdProgressStore(sources: .unanswered))
                .environment(ToastCenter())
                .environment(AllWorkspacesModeStore(userDefaults: defaults))
                .environment(MissionBottomLineStore(userDefaults: defaults))
                .environment(identity)
                .environment(picker)
                .frame(width: width + ChromeMetrics.ruleWidth, height: ProfilePickerRenderTests.railHeight, alignment: .topLeading)
        }
    }

    func testThePickerTopsTheRailWithAMachinesMarkerAndDot() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let defaults = try scratchDefaults()
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        viewModel.update(model: model(), connection: .live)
        let pickers = try Self.columns.map { try picker(current: $0.current) }
        let totalWidth = Self.columns.reduce(Self.gap) { $0 + $1.width + ChromeMetrics.ruleWidth + Self.gap }
        let size = CGSize(width: totalWidth, height: Self.railHeight + Self.gap * 2)
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let themeStore = ThemeStore(userDefaults: defaults)
            themeStore.select(theme)
            let view = HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Self.columns.indices, id: \.self) { index in
                    Probe(
                        theme: theme, viewModel: viewModel, picker: pickers[index], dot: Self.columns[index].dot,
                        width: Self.columns[index].width, defaults: defaults, identity: identity, themeStore: themeStore
                    )
                }
            }
            .padding(Self.gap)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(theme.canvas)
            let image = try await render(view, size: size)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("profile-picker-rail-\(scheme).png"))
            }
            var x = Self.gap
            let band = (Self.gap + ChromeMetrics.Rail.verticalPadding, Self.gap + ChromeMetrics.Rail.verticalPadding + 29)
            for (index, column) in Self.columns.enumerated() {
                let rect = CGRect(x: x, y: band.0, width: column.width, height: band.1 - band.0)
                let green = contains(image, rect, Color(theme.palette.green))
                let yellow = contains(image, rect, Color(theme.palette.yellow))
                switch column.dot {
                case nil:
                    XCTAssertFalse(green || yellow, "\(scheme) column \(index): a local profile shows no dot")
                case .live:
                    XCTAssertTrue(green, "\(scheme) column \(index): a live machine's dot is green")
                case .attention:
                    XCTAssertTrue(yellow, "\(scheme) column \(index): a machine with a notice has a yellow dot")
                }
                x += column.width + ChromeMetrics.ruleWidth + Self.gap
            }
        }
        for picker in pickers {
            XCTAssertTrue(picker.canOpen, "a mounted picker lets the shortcut open it")
        }
    }

    func testTheListOpensOnTheCurrentProfileWithMachinesAfterARule() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let local = try picker(current: FlockProfile.defaultID)
        let machine = try picker(current: "machine.\(Self.mini.id)")
        let models = [
            ProfilePickerModel(profiles: local.profiles.profiles, currentID: local.profiles.currentID, currentDot: nil),
            ProfilePickerModel(profiles: machine.profiles.profiles, currentID: machine.profiles.currentID, currentDot: .live),
        ]
        let states: [[Int: ControlInteraction]] = [[:], [1: .hover]]
        let column = ChromeMetrics.ProfilePicker.listWidth + Self.gap * 2
        let size = CGSize(width: column * 2, height: 260)
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let view = HStack(alignment: .top, spacing: 0) {
                ForEach(models.indices, id: \.self) { index in
                    ProfilePickerList(theme: theme, model: models[index], onChoose: { _ in }, onClose: {}, forced: states[index])
                        .padding(Self.gap)
                        .frame(width: column, alignment: .topLeading)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(theme.chrome)
            let image = try await render(view, size: size)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("profile-picker-list-\(scheme).png"))
            }
            let selection = Color(theme.palette.chromeRoles.selection)
            let firstRow = CGRect(x: Self.gap + 9, y: Self.gap + 10, width: 6, height: 16)
            XCTAssertTrue(contains(image, firstRow, selection), "\(scheme): the list opens picked on Default")
            XCTAssertFalse(contains(image, firstRow.offsetBy(dx: column, dy: 0), selection), "\(scheme): Default is not picked on a machine")
        }
    }

    private func scratchDefaults() throws -> UserDefaults {
        let suite = "ProfilePickerRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func picker(current: String) throws -> ProfilePickerContext {
        let store = ProfileStore(
            userDefaults: try scratchDefaults(), bundleID: "dev.acme.flock-tests", defaultSocketPath: "/tmp/acme.sock",
            home: "/Users/acme", removeSuite: { _ in }
        )
        _ = store.create(name: "Demo", socketPath: nil)
        store.syncMachines([Self.mini, Self.longMini])
        store.select(current)
        return ProfilePickerContext(profiles: store, isLocked: false, switchProfile: { _ in false }, listMachines: { nil })
    }

    private func model() -> SessionModel {
        let ids = [WorkspaceID(rawValue: "w1"), WorkspaceID(rawValue: "w2")]
        let labels = ["acme", "web"]
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: ids[0], focusedTabID: nil, focusedPaneID: nil,
            workspaces: ids.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: labels[index], number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: .idle
                )
            },
            tabs: ids.map { id in
                TabRecord(tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "first", number: 1, paneCount: 1, agentStatus: .idle)
            },
            panes: [],
            layouts: []
        ))
    }

    private func render(_ view: some View, size: CGSize) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: view)
        defer { window.close() }
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * Self.scale), height: Int(bounds.height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.scale, y: Self.scale)
        content.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// Whether any pixel in `rect` (points, top-left origin) is within a few
    /// channel steps of `color`.
    private func contains(_ image: NSBitmapImageRep, _ rect: CGRect, _ color: Color) -> Bool {
        guard let target = NSColor(color).usingColorSpace(.sRGB), let data = image.bitmapData else { return false }
        let want = [target.redComponent, target.greenComponent, target.blueComponent].map { Int(($0 * 255).rounded()) }
        let stride = image.bitsPerPixel / 8
        for y in Int(rect.minY * Self.scale)..<Int(rect.maxY * Self.scale) where y >= 0 && y < image.pixelsHigh {
            for x in Int(rect.minX * Self.scale)..<Int(rect.maxX * Self.scale) where x >= 0 && x < image.pixelsWide {
                let offset = y * image.bytesPerRow + x * stride
                let have = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
                if zip(have, want).allSatisfy({ abs($0 - $1) <= 4 }) { return true }
            }
        }
        return false
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}
