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

    private static let pickerHeight = ChromeMetrics.WorkspaceRow.contentHeight + 2 * ChromeMetrics.ProfilePicker.verticalPadding

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
            let band = (Self.gap + ChromeMetrics.Rail.verticalPadding, Self.gap + ChromeMetrics.Rail.verticalPadding + Self.pickerHeight)
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
                    ProfilePickerList(
                        theme: theme, model: models[index], onChoose: { _ in }, onManage: {}, onClose: {}, forced: states[index]
                    )
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
            let metrics = ChromeMetrics.ProfilePicker.self
            let selection = Color(theme.palette.chromeRoles.selection)
            // Past the names and short of the return glyph, clear of the
            // fill's rounded corners.
            let scanX = Self.gap + metrics.listWidth * 0.7
            let localRuns = runs(image, x: scanX, color: selection)
            let machineRuns = runs(image, x: column + scanX, color: selection)
            XCTAssertEqual(localRuns.count, 1, "\(scheme): one picked row on a local profile")
            XCTAssertEqual(machineRuns.count, 1, "\(scheme): one picked row on a machine")
            guard let local = localRuns.first, let machine = machineRuns.first else { continue }
            let listTop = Self.gap + metrics.listVerticalPadding
            XCTAssertEqual(local.lowerBound, listTop, accuracy: 1.5, "\(scheme): Default, the current row, is picked")
            let row = local.upperBound - local.lowerBound
            let sectionRule = metrics.listSectionGap * 2 + ChromeMetrics.ruleWidth
            let firstMachine = listTop + 2 * (row + metrics.listRowSpacing) + sectionRule + metrics.listRowSpacing
            XCTAssertEqual(machine.lowerBound, firstMachine, accuracy: 1.5, "\(scheme): acme-mini, the current row, is picked")
        }
    }

    /// While a machine is connecting, unreachable, not running or removed the
    /// rail is gone; the picker stays where the rail draws it, so it and the
    /// shortcut still work.
    func testTheMachineScreenKeepsThePickerWhereTheRailDrawsIt() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let picker = try picker(current: "machine.\(Self.mini.id)")
        let size = CGSize(width: 900, height: 560)
        let message = "Can't reach acme-mini. Permission denied (publickey). If your key has a passphrase, run ssh-add, then check that ssh acme-mini works."
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let screen = NoHerdrScreen(
                theme: theme, copy: NoHerdrScreen.machine(label: "acme-mini", message: message),
                profilePicker: picker, profileDot: .attention
            )
            let image = try await render(screen.frame(width: size.width, height: size.height), size: size)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("profile-picker-machine-screen-\(scheme).png"))
            }
            let top = ChromeMetrics.TitleBar.height + ChromeMetrics.Rail.verticalPadding
            let band = CGRect(
                x: ChromeMetrics.Rail.horizontalPadding, y: top,
                width: RailWidth.default - 2 * ChromeMetrics.Rail.horizontalPadding, height: Self.pickerHeight
            )
            XCTAssertTrue(contains(image, band, Color(theme.palette.yellow)), "\(scheme): the picker shows the machine's dot")
        }
        XCTAssertTrue(picker.canOpen, "the machine screen's picker lets the shortcut open it")
    }

    /// ⌃`'s panel: Default current with the last-used machine selected, then
    /// acme-mini current with its live dot and Default selected. The panel's
    /// rows are the switcher's, the marker and dot the picker's.
    func testTheProfileSwitcherShowsMachinesWithTheirMarkerAndTheCurrentDot() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let column = CGSize(width: 480, height: 400)
        let miniID = "machine.\(Self.mini.id)"
        let cases: [(current: String, dot: ProfileConnectionDot?)] = [(FlockProfile.defaultID, nil), (miniID, .live)]
        let size = CGSize(width: column.width * CGFloat(cases.count), height: column.height)
        typealias Metrics = ChromeMetrics.Palette
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let pickers = try cases.map { try picker(current: $0.current) }
            let switchers = try cases.indices.map { index in
                let switcher = ProfileSwitcher(userDefaults: try scratchDefaults())
                switcher.note(currentProfile: cases[index].current == miniID ? FlockProfile.defaultID : miniID)
                switcher.note(currentProfile: cases[index].current)
                let profiles = pickers[index].profiles
                XCTAssertTrue(switcher.begin(
                    items: ProfileSwitcher.candidates(profiles.profiles, isLocked: false),
                    current: ProfileID(rawValue: profiles.currentID)
                ))
                switcher.show(session: switcher.session)
                return switcher
            }
            let view = HStack(spacing: 0) {
                ForEach(cases.indices, id: \.self) { index in
                    ProfileSwitcherOverlay(
                        theme: theme, switcher: switchers[index], profiles: pickers[index].profiles, isLocked: false,
                        currentDot: cases[index].dot, blocked: { false }, choose: { _ in }
                    )
                    .frame(width: column.width, height: column.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(theme.chrome)
            let image = try await render(view, size: size)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("profile-switcher-\(scheme).png"))
            }

            XCTAssertEqual(switchers[0].order.first?.rawValue, FlockProfile.defaultID)
            XCTAssertEqual(switchers[0].selected?.rawValue, miniID, "\(scheme): a tap from Default goes to the machine")
            XCTAssertEqual(switchers[1].selected?.rawValue, FlockProfile.defaultID, "\(scheme): and back")
            let rowCount = switchers[0].order.count
            let area = column.height - ChromeMetrics.TitleBar.height
            let top = ChromeMetrics.TitleBar.height + ChromeMetrics.Switcher.top(inTabAreaHeight: area, rowCount: rowCount)
            let rowY = { (index: Int) in
                top + ChromeMetrics.Switcher.headerHeight + ChromeMetrics.ruleWidth + Metrics.listPadding + CGFloat(index) * (Metrics.rowHeight + 1)
            }
            let boxX = (column.width - ChromeMetrics.Switcher.width) / 2
            let selection = Color(theme.palette.chromeRoles.selection)
            for index in cases.indices {
                let x = CGFloat(index) * column.width + boxX
                let highlight = CGRect(x: x + ChromeMetrics.Switcher.width - 40, y: rowY(1) + 3, width: 8, height: 4)
                XCTAssertTrue(contains(image, highlight, selection), "\(scheme) column \(index): the second row is selected")
                let currentRow = CGRect(x: x, y: rowY(0), width: ChromeMetrics.Switcher.width, height: Metrics.rowHeight)
                let green = contains(image, currentRow, Color(theme.palette.green))
                XCTAssertEqual(green, cases[index].dot == .live, "\(scheme) column \(index): only a current machine shows its dot")
            }
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

    /// The vertical spans, in points, where the column of pixels at `x`
    /// matches `color`.
    private func runs(_ image: NSBitmapImageRep, x: CGFloat, color: Color) -> [ClosedRange<CGFloat>] {
        guard let target = NSColor(color).usingColorSpace(.sRGB), let data = image.bitmapData else { return [] }
        let want = [target.redComponent, target.greenComponent, target.blueComponent].map { Int(($0 * 255).rounded()) }
        let px = Int(x * Self.scale)
        var spans: [ClosedRange<CGFloat>] = []
        var start: Int?
        for y in 0...image.pixelsHigh {
            var matches = false
            if y < image.pixelsHigh {
                let offset = y * image.bytesPerRow + px * (image.bitsPerPixel / 8)
                let have = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
                matches = zip(have, want).allSatisfy { abs($0 - $1) <= 4 }
            }
            if matches, start == nil { start = y }
            if !matches, let first = start {
                spans.append(CGFloat(first) / Self.scale...CGFloat(y) / Self.scale)
                start = nil
            }
        }
        return spans
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
