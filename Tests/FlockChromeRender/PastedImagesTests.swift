import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Pasted images from the paste to the pixels: which label an image is given,
/// what is kept across launches, and the chips, tray, preview and drop target
/// in a dark and a light theme. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PastedImagesTests: XCTestCase {
    private nonisolated(unsafe) var directory: URL!
    private nonisolated(unsafe) var staging: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-pasted-\(UUID().uuidString)")
        directory = root.appendingPathComponent("kept")
        staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private static let cell = CGSize(width: 8, height: 17)
    private static let paneSize = CGSize(width: 900, height: 17 * 24)
    private static let conversation = "acme-conversation"
    private static let rule = String(repeating: "\u{2500}", count: 110)
    private static let sentGround = PastedImagesModel.Ground(red: 48, green: 48, blue: 52)

    private final class FakePane {
        var rows: [String] = []
        var isOnScreen = true
    }

    private func store(now: Date = Date()) -> PastedImageStore {
        PastedImageStore(directory: directory, stagingDirectory: staging, now: now)
    }

    private func model(on pane: FakePane, store: PastedImageStore) -> PastedImagesModel {
        let model = PastedImagesModel(store: { store })
        model.pane = PastedImagesModel.Pane(
            screen: { whole in
                guard pane.isOnScreen else { return nil }
                let held = pane.rows.contains { row in PastedImageLabels.markers.contains(where: row.contains) }
                return PastedImagesModel.Screen(rows: whole || held ? pane.rows : [], cell: Self.cell) { point in
                    let row = Int(point.y / Self.cell.height)
                    return pane.rows.indices.contains(row) && pane.rows[row].hasPrefix("> ") ? Self.sentGround : nil
                }
            },
            frame: { nil }, window: { nil }, toScreen: { $0 }, fromWindow: { $0 }
        )
        return model
    }

    private func picture(_ name: String, width: Int, height: Int, hue: CGFloat, in folder: URL? = nil) throws -> String {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor(hue: hue, saturation: 0.12, brightness: 0.98, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.6, alpha: 1).cgColor)
        for line in 0..<6 {
            context.fill(CGRect(
                x: width / 12, y: height * (line + 1) / 8, width: width * (10 - line) / 14, height: max(2, height / 24)))
        }
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let url = (folder ?? directory.deletingLastPathComponent()).appendingPathComponent(name)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    private func pictures(_ count: Int) throws -> [String] {
        let sizes = [(800, 500), (500, 900), (1000, 260), (640, 640), (700, 420)]
        return try (0..<count).map {
            let size = sizes[$0 % sizes.count]
            return try picture("shot \($0).png", width: size.0, height: size.1, hue: CGFloat($0) / CGFloat(count))
        }
    }

    private func screen(prompt: String) -> [String] {
        let transcript = [
            "", "> [Image #1]look at this one", "  \u{23BF}  [Image #1]", "",
            "\u{25CF} The header stays put while the list scrolls, and the", "  sidebar collapses below 900 points.", "",
        ]
        let rows = transcript + Array(repeating: "", count: 12) + [Self.rule, prompt, Self.rule, "  acme | medium"]
        return rows + Array(repeating: "", count: 24 - rows.count)
    }

    /// Pastes `paths` one after another and waits for their images.
    private func paste(_ paths: [String], into model: PastedImagesModel, on pane: FakePane) async throws {
        pane.rows = []
        _ = model.willPaste(paths)
        pane.rows = screen(prompt: "\u{276F} " + paths.indices.map { "[Image #\($0 + 1)]" }.joined(separator: " "))
        model.refresh()
        try await loaded(paths.count, in: model)
    }

    private func loaded(_ count: Int, in model: PastedImagesModel) async throws {
        for _ in 0..<100 where model.images.count < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.images.count, count)
    }

    // MARK: - Matching and keeping

    func testPastedImagesTakeTheirLabelsAndAreKeptForTheConversation() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(3)
        try await paste(paths, into: model, on: pane)
        XCTAssertEqual(model.promptNumbers, [1, 2, 3])
        XCTAssertEqual(store.images(for: Self.conversation), [1: paths[0], 2: paths[1], 3: paths[2]])
    }

    func testAnotherLaunchShowsTheSameImages() async throws {
        let pane = FakePane()
        let first = model(on: pane, store: store())
        first.bind(conversation: Self.conversation)
        try await paste(try pictures(2), into: first, on: pane)

        let second = model(on: pane, store: store())
        second.bind(conversation: Self.conversation)
        second.refresh()
        try await loaded(2, in: second)
    }

    func testImagesPastedBeforeTheConversationIsKnownJoinIt() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        try await paste(try pictures(1), into: model, on: pane)
        XCTAssertEqual(store.images(for: Self.conversation), [:])
        model.bind(conversation: Self.conversation)
        XCTAssertEqual(store.images(for: Self.conversation).count, 1)
    }

    func testANewConversationStartsWithNoImages() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        model.bind(conversation: Self.conversation)
        try await paste(try pictures(1), into: model, on: pane)
        pane.rows = []
        model.refresh()
        model.bind(conversation: "acme-after-clear")
        pane.rows = screen(prompt: "\u{276F} [Image #1]")
        model.refresh()
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertTrue(model.promptNumbers.isEmpty)
    }

    func testAPasteBeforeANewConversationsIdArrivesMovesToItAndGivesTheOldOneBack() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        let old = try picture("old.png", width: 40, height: 40, hue: 0.2)
        _ = store.keep(old, as: 1, in: Self.conversation)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(1)
        try await paste(paths, into: model, on: pane)
        for _ in 0..<50 where model.images[1]?.path != paths[0] { try await Task.sleep(for: .milliseconds(20)) }
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.images(for: "acme-after-clear"), [1: paths[0]])
        XCTAssertEqual(store.images(for: Self.conversation), [1: old])
        XCTAssertEqual(model.images[1]?.path, paths[0])
    }

    func testAnImageSentBeforeANewConversationsIdArrivesMovesToIt() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        let old = try picture("old.png", width: 40, height: 40, hue: 0.2)
        _ = store.keep(old, as: 1, in: Self.conversation)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(1)
        try await paste(paths, into: model, on: pane)
        pane.rows = screen(prompt: "\u{276F} ")
        model.refresh()
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.images(for: "acme-after-clear"), [1: paths[0]])
        XCTAssertEqual(store.images(for: Self.conversation), [1: old])
    }

    func testANewConversationThatArrivesOffScreenWaitsForTheScreen() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(1)
        try await paste(paths, into: model, on: pane)
        pane.isOnScreen = false
        model.refresh()
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.images(for: "acme-after-clear"), [:])
        pane.isOnScreen = true
        model.refresh()
        XCTAssertEqual(store.images(for: "acme-after-clear"), [1: paths[0]])
    }

    func testAConversationThatComesBackBeforeTheScreenDoesIsLeftAsItWas() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(1)
        try await paste(paths, into: model, on: pane)
        pane.isOnScreen = false
        model.bind(conversation: "acme-passing")
        model.bind(conversation: Self.conversation)
        pane.isOnScreen = true
        model.refresh()
        XCTAssertEqual(store.images(for: "acme-passing"), [:])
        XCTAssertEqual(store.images(for: Self.conversation), [1: paths[0]])
    }

    func testTheOldConversationGetsBackWhatItLastHeld() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        let original = try picture("original.png", width: 40, height: 40, hue: 0.2)
        _ = store.keep(original, as: 1, in: Self.conversation)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(2)
        try await paste([paths[0]], into: model, on: pane)
        try await paste([paths[1]], into: model, on: pane)
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.images(for: Self.conversation), [1: paths[0]])
        XCTAssertEqual(store.images(for: "acme-after-clear"), [1: paths[1]])
    }

    func testAResumedConversationKeepsItsOwnImages() async throws {
        let pane = FakePane()
        let store = store()
        let resumed = try picture("resumed.png", width: 40, height: 40, hue: 0.4)
        _ = store.keep(resumed, as: 1, in: "acme-resumed")
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        let paths = try pictures(1)
        try await paste(paths, into: model, on: pane)
        model.bind(conversation: "acme-resumed")
        XCTAssertEqual(store.images(for: "acme-resumed"), [1: resumed])
        XCTAssertEqual(store.images(for: Self.conversation), [1: paths[0]])
        model.refresh()
        for _ in 0..<50 where model.images[1]?.path != resumed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.images[1]?.path, resumed)
    }

    func testAnAgentThatExitsLeavesItsImagesWithItsOwnConversation() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        try await paste(try pictures(1), into: model, on: pane)
        pane.rows = []
        model.refresh()
        model.bind(conversation: nil)
        XCTAssertFalse(model.hasConversation)
        model.bind(conversation: "acme-next")
        XCTAssertEqual(store.images(for: "acme-next"), [:])
        XCTAssertEqual(store.images(for: Self.conversation).count, 1)
    }

    func testScrollingWhileAFirstPasteWaitsTakesNoOldLabel() throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        pane.rows = [Self.rule, "\u{276F} ", Self.rule]
        _ = model.willPaste(try pictures(1))
        pane.rows = ["> [Image #1] an old one", "  \u{23BF}  [Image #1]"]
        model.refresh()
        XCTAssertEqual(store.images(for: Self.conversation), [:])
    }

    func testAPasteWaitingWhenTheConversationChangesIsDropped() async throws {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        _ = model.willPaste(try pictures(1))
        model.bind(conversation: "acme-after-clear")
        pane.rows = ["[Image #1]"]
        model.refresh()
        XCTAssertEqual(store.images(for: "acme-after-clear"), [:])
    }

    func testAReplacementThatCannotLoadTakesTheOldImageWithIt() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        _ = model.willPaste(try pictures(1))
        pane.rows = ["[Image #1]"]
        model.refresh()
        try await loaded(1, in: model)
        _ = model.willPaste(["/nonexistent/acme.png"])
        pane.rows = ["[Image #1] [Image #1]"]
        model.refresh()
        for _ in 0..<50 where !model.images.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.images.isEmpty)
    }

    func testAPasteStillWaitsWhileItsPaneIsOffScreen() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        let path = try XCTUnwrap(pictures(1).first)
        pane.rows = ["[Image #4]"]
        _ = model.willPaste([path])
        pane.isOnScreen = false
        model.refresh()
        XCTAssertTrue(model.labels.isEmpty)
        pane.isOnScreen = true
        model.refresh()
        XCTAssertNil(model.images[4])
        pane.rows = ["[Image #4] [Image #5]"]
        model.refresh()
        try await loaded(1, in: model)
        XCTAssertEqual(model.images[5]?.path, path)
    }

    func testAFileThatIsGoneIsLeftAsText() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        pane.rows = []
        _ = model.willPaste(["/nonexistent/acme.png"])
        pane.rows = ["[Image #1]"]
        model.refresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertNil(model.label(at: CGPoint(x: 4, y: 4)))
    }

    // MARK: - Dropped files

    private static let droppedScreen = [
        "", "> [Pasted text #1] what does this do", "  \u{23BF}  Read it", "",
        "\u{25CF} It exports one icon.", "",
    ] + Array(repeating: "", count: 12) + [
        rule, "\u{276F} see [Pasted text #2] [Pasted text #3]and the one that does not fit [Pasted",
        "  text #14]", rule, "  acme | medium", "",
    ]

    private func drop(_ names: [String], into model: PastedImagesModel, on pane: FakePane) {
        pane.rows = [Self.rule, "\u{276F} ", Self.rule]
        for name in names { model.willDrop("/Users/acme/app/\(name)") }
        pane.rows = Self.droppedScreen
        model.refresh()
    }

    func testDroppedFilesTakeTheirLabelsAndAreKeptForTheConversation() {
        let pane = FakePane()
        let store = store()
        let first = model(on: pane, store: store)
        first.bind(conversation: Self.conversation)
        drop(["b.js", "c.js", "d.js"], into: first, on: pane)
        XCTAssertEqual(first.files.map(\.name), ["b.js", "c.js", "d.js"])
        XCTAssertTrue(first.images.isEmpty)

        let second = model(on: pane, store: self.store())
        second.bind(conversation: Self.conversation)
        second.refresh()
        XCTAssertEqual(second.files.map(\.path), first.files.map(\.path))
        XCTAssertEqual(second.files.map(\.runs), first.files.map(\.runs))
    }

    func testAFileDroppedBeforeItsConversationsIdArrivesMovesToIt() {
        let pane = FakePane()
        let store = store()
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        drop(["b.js"], into: model, on: pane)
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.files(for: "acme-after-clear"), [2: "/Users/acme/app/b.js"])
    }

    func testTheOldConversationGetsItsFileBackWhenADropWasAnothers() {
        let pane = FakePane()
        let store = store()
        store.keep("/Users/acme/app/old.js", asFile: 2, in: Self.conversation)
        let model = model(on: pane, store: store)
        model.bind(conversation: Self.conversation)
        drop(["b.js"], into: model, on: pane)
        model.bind(conversation: "acme-after-clear")
        XCTAssertEqual(store.files(for: "acme-after-clear"), [2: "/Users/acme/app/b.js"])
        XCTAssertEqual(store.files(for: Self.conversation), [2: "/Users/acme/app/old.js"])
    }

    func testShowingAnOldConversationsFilesKeepsThem() {
        let old = Date().addingTimeInterval(-PastedImageIndex.maximumAge + 60)
        store(now: old).keep("/Users/acme/app/b.js", asFile: 2, in: Self.conversation, now: old)
        let pane = FakePane()
        pane.rows = Self.droppedScreen
        let model = model(on: pane, store: store())
        model.bind(conversation: Self.conversation)
        model.refresh()
        XCTAssertEqual(store(now: Date().addingTimeInterval(120)).files(for: Self.conversation).count, 1)
    }

    func testAPromptIsSeenWithNoLabelOnScreen() {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        pane.rows = [Self.rule, "\u{276F} ", Self.rule]
        XCTAssertTrue(model.promptIsDrawn)
        pane.rows = ["Do you want to proceed?", "1. Yes"]
        XCTAssertFalse(model.promptIsDrawn)
    }

    /// The program's own label is under the chip, so a dimmed pane's chip is
    /// dimmed and never see-through.
    func testAFileChipInADimmedPaneStillCoversItsLabel() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        drop(["b.js"], into: model, on: pane)
        let chip = try XCTUnwrap(model.files.first?.chip)
        let shade = SurfaceShade(drain: 0, veil: 0.44)
        var images: [NSBitmapImageRep] = []
        for (rows, name) in [(pane.rows, "label"), ([], "bare")] {
            images.append(try await render(
                Scene(theme: .tokyoNight, rows: rows) {
                    PastedImagesOverlay(
                        theme: .tokyoNight, model: model, space: "pane", fontSizePoints: 13, shade: shade,
                        showsTray: false)
                },
                name: "dimmed-\(name)"))
        }
        for x in stride(from: chip.minX + 4, to: chip.maxX - 4, by: 3) {
            for y in [chip.minY + 5, chip.midY, chip.maxY - 5] {
                let colors = try images.map { image -> [UInt8] in
                    let data = try XCTUnwrap(image.bitmapData)
                    let offset = Int(y * 2) * image.bytesPerRow + Int(x * 2) * (image.bitsPerPixel / 8)
                    return [data[offset], data[offset + 1], data[offset + 2]]
                }
                XCTAssertEqual(colors[0], colors[1], "the label shows through at \(x), \(y)")
            }
        }
    }

    func testAWrappedLabelsChipIsOnItsLongerRowAndNothingElseIsPressed() throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        drop(["b.js", "c.js", "d.js"], into: model, on: pane)
        let wrapped = try XCTUnwrap(model.files.last)
        XCTAssertEqual(wrapped.runs.count, 2)
        XCTAssertEqual(wrapped.chip.minY, wrapped.runs[1].minY)
        XCTAssertNil(model.file(at: CGPoint(x: wrapped.runs[0].midX, y: wrapped.runs[0].midY)))
        XCTAssertEqual(model.file(at: CGPoint(x: wrapped.chip.midX, y: wrapped.chip.midY))?.name, "d.js")
    }

    func testFileChipsTakeTheConfirmCardsGroundInBothThemes() async throws {
        for (theme, name) in [(Theme.tokyoNight, "dark"), (Self.light, "light")] {
            let pane = FakePane()
            let store = store()
            store.keep("/Users/acme/app/a.swift", asFile: 1, in: Self.conversation)
            let model = model(on: pane, store: store)
            model.bind(conversation: Self.conversation)
            drop(["ZoomInOutlined.d.ts", "clipboard.js", "notes.md"], into: model, on: pane)
            model.highlightFile(3)
            let image = try await render(
                Scene(theme: theme, rows: pane.rows) { self.overlay(model, theme: theme) }, name: "files-\(name)")
            let chip = try XCTUnwrap(model.files.first { $0.number == 2 }?.chip)
            try assertPixel(
                image, at: CGPoint(x: chip.maxX - 2.5, y: chip.midY), is: theme.confirmCardColors.ground, "\(name) chip")
        }
    }

    // MARK: - The store

    func testAStagedImageIsCopiedAndAnOrdinaryFileIsPointedAt() throws {
        let store = store()
        let staged = try picture("clipboard-1.png", width: 20, height: 20, hue: 0, in: staging)
        let own = try picture("own.png", width: 20, height: 20, hue: 0)
        let kept = store.keep(staged, as: 1, in: Self.conversation)
        XCTAssertEqual(kept, directory.appendingPathComponent("clipboard-1.png").path)
        XCTAssertEqual(store.keep(own, as: 2, in: Self.conversation), own)
        let mode = try FileManager.default.attributesOfItem(atPath: kept)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testALaunchDeletesOnlyCopiesNothingUses() throws {
        let old = Date().addingTimeInterval(-PastedImageIndex.maximumAge - 60)
        let first = store()
        func staged(_ name: String) throws -> String {
            try picture(name, width: 20, height: 20, hue: 0, in: staging)
        }
        let stale = first.keep(try staged("clipboard-2.png"), as: 1, in: "acme-old", now: old)
        let replaced = first.keep(try staged("clipboard-3.png"), as: 1, in: Self.conversation)
        let kept = first.keep(try staged("clipboard-4.png"), as: 1, in: Self.conversation)
        let own = try picture("own.png", width: 20, height: 20, hue: 0)
        _ = first.keep(own, as: 2, in: "acme-old", now: old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced), "deleted while its label may come back")

        let second = store()
        XCTAssertEqual(second.images(for: "acme-old"), [:])
        XCTAssertEqual(second.images(for: Self.conversation), [1: kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own))
    }

    func testShowingAnOldConversationsImagesKeepsThem() async throws {
        let old = Date().addingTimeInterval(-PastedImageIndex.maximumAge + 60)
        let first = store(now: old)
        _ = first.keep(try picture("own.png", width: 20, height: 20, hue: 0), as: 1, in: Self.conversation, now: old)
        let pane = FakePane()
        pane.rows = ["[Image #1]"]
        let model = model(on: pane, store: store())
        model.bind(conversation: Self.conversation)
        model.refresh()
        XCTAssertEqual(store(now: Date().addingTimeInterval(120)).images(for: Self.conversation).count, 1)
    }

    // MARK: - Pixels

    private static var light: Theme {
        Theme.builtins.first { $0.id == ThemePalette.tokyoNightDay.id } ?? .tokyoNight
    }

    private struct Scene<Content: View>: View {
        let theme: Theme
        let rows: [String]
        @ViewBuilder let content: () -> Content

        var body: some View {
            ZStack(alignment: .topLeading) {
                theme.terminalGround
                ForEach(Array(rows.enumerated()), id: \.offset) { row, line in
                    if line.hasPrefix("> ") {
                        Color(.displayP3, red: 48 / 255, green: 48 / 255, blue: 52 / 255)
                            .frame(height: PastedImagesTests.cell.height)
                            .offset(y: CGFloat(row) * PastedImagesTests.cell.height)
                    }
                    ForEach(Array(line.enumerated()), id: \.offset) { column, character in
                        Text(String(character))
                            .font(.custom(TerminalFont.face, fixedSize: 13))
                            .foregroundStyle(line.hasPrefix("> ") ? .white : theme.terminalForeground)
                            .frame(width: PastedImagesTests.cell.width, height: PastedImagesTests.cell.height)
                            .offset(
                                x: CGFloat(column) * PastedImagesTests.cell.width,
                                y: CGFloat(row) * PastedImagesTests.cell.height)
                    }
                }
                content()
            }
            .frame(width: PastedImagesTests.paneSize.width, height: PastedImagesTests.paneSize.height)
            .coordinateSpace(name: "pane")
        }
    }

    private func render(_ view: some View, name: String) async throws -> NSBitmapImageRep {
        ChromeType.install()
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.paneSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let scale: CGFloat = 2
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(Self.paneSize.width * scale), height: Int(Self.paneSize.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        hosting.displayIgnoringOpacity(hosting.bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        if let folder = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("pasted-images-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    private func assertPixel(
        _ image: NSBitmapImageRep, at point: CGPoint, is expected: RGB, _ message: String, line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(image.bitmapData)
        let offset = Int(point.y * 2) * image.bytesPerRow + Int(point.x * 2) * (image.bitsPerPixel / 8)
        for (channel, value) in [expected.red, expected.green, expected.blue].enumerated() {
            XCTAssertEqual(Int(data[offset + channel]), value, accuracy: 4, message, line: line)
        }
    }

    private func overlay(_ model: PastedImagesModel, theme: Theme, showsTray: Bool = true) -> some View {
        PastedImagesOverlay(
            theme: theme, model: model, space: "pane", fontSizePoints: 13, shade: .none, showsTray: showsTray)
    }

    func testChipsAndTrayTakeTheConfirmCardsGroundInBothThemes() async throws {
        for (theme, name) in [(Theme.tokyoNight, "dark"), (Self.light, "light")] {
            for count in [2, 8] {
                let pane = FakePane()
                let model = model(on: pane, store: store())
                try await paste(try pictures(count), into: model, on: pane)
                if count == 8 { model.highlight(8) }
                let image = try await render(
                    Scene(theme: theme, rows: pane.rows) { self.overlay(model, theme: theme) }, name: "tray-\(count)-\(name)")
                let tray = try XCTUnwrap(model.trayFrame, "\(name): no tray")
                XCTAssertTrue(CGRect(origin: .zero, size: Self.paneSize).contains(tray), "\(name): \(tray)")
                XCTAssertLessThanOrEqual(tray.maxY, try XCTUnwrap(model.promptTop), "\(name): over the prompt")
                let ground = theme.confirmCardColors.ground
                try assertPixel(image, at: CGPoint(x: tray.minX + 4, y: tray.midY), is: ground, "\(name) tray")
                let chip = try XCTUnwrap(model.labels.first { $0.number == 2 }?.rect)
                try assertPixel(
                    image, at: CGPoint(x: chip.minX + Self.cell.width * 2.4, y: chip.minY + 3), is: ground, "\(name) chip")
            }
        }
    }

    /// The chip covers its label with the row's own color, so a sent
    /// message's highlight runs unbroken round it.
    func testAChipOnAHighlightedRowKeepsTheRowsColorRoundIt() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        try await paste(try pictures(1), into: model, on: pane)
        let sent = try XCTUnwrap(model.labels.first { !$0.inPrompt && !$0.isAttachmentLine })
        XCTAssertEqual(sent.ground, Self.sentGround)
        let image = try await render(
            Scene(theme: .tokyoNight, rows: pane.rows) { self.overlay(model, theme: .tokyoNight, showsTray: false) },
            name: "sent-dark")
        let after = CGPoint(x: sent.rect.maxX - 1, y: sent.rect.midY)
        let beside = CGPoint(x: sent.rect.minX - 4, y: sent.rect.midY + 6)
        let data = try XCTUnwrap(image.bitmapData)
        func red(_ point: CGPoint) -> Int {
            Int(data[Int(point.y * 2) * image.bytesPerRow + Int(point.x * 2) * (image.bitsPerPixel / 8)])
        }
        XCTAssertEqual(red(after), red(beside), accuracy: 3)
    }

    /// A program in a dark theme of its own draws dark rows in a light pane.
    func testAChipStandsOutFromADarkRowInALightTheme() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        try await paste(try pictures(1), into: model, on: pane)
        let sent = try XCTUnwrap(model.labels.first { !$0.inPrompt && !$0.isAttachmentLine })
        let image = try await render(
            Scene(theme: Self.light, rows: pane.rows) { self.overlay(model, theme: Self.light, showsTray: false) },
            name: "sent-light")
        try assertPixel(
            image, at: CGPoint(x: sent.rect.minX + Self.cell.width * 2.4, y: sent.rect.minY + 3),
            is: ChromeMetrics.ConfirmCard.Colors.light.ground, "chip on a dark row")
    }

    func testAnImageScrolledAwayIsLetGoAndComesBack() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        var now = Date()
        model.now = { now }
        try await paste(try pictures(1), into: model, on: pane)
        let rows = pane.rows
        pane.rows = []
        model.refresh()
        now += PastedImagesModel.keptOffScreen - 1
        model.refresh()
        XCTAssertNotNil(model.images[1])
        now += 2
        model.refresh()
        XCTAssertNil(model.images[1])
        pane.rows = rows
        model.refresh()
        for _ in 0..<500 where model.images[1] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.images[1])

        pane.isOnScreen = false
        now += PastedImagesModel.keptOffScreen * 10
        model.refresh()
        XCTAssertNotNil(model.images[1], "a hidden pane comes back with its images")
    }

    func testNoTrayWhileThePaneIsBeingArranged() async throws {
        let pane = FakePane()
        let model = model(on: pane, store: store())
        try await paste(try pictures(2), into: model, on: pane)
        _ = try await render(
            Scene(theme: .tokyoNight, rows: pane.rows) { self.overlay(model, theme: .tokyoNight, showsTray: false) },
            name: "no-tray-dark")
        XCTAssertNil(model.trayFrame)
    }

    func testThePreviewAndTheDropTargetInBothThemes() async throws {
        let wide = try XCTUnwrapped(await PastedImage.load(try picture("wide.png", width: 1000, height: 260, hue: 0.6)))
        let small = try XCTUnwrapped(await PastedImage.load(try picture("small.png", width: 90, height: 70, hue: 0.1)))
        for (theme, name) in [(Theme.tokyoNight, "dark"), (Self.light, "light")] {
            let anchor = LinkChip.Anchor(x: 200, lineTop: 340, lineBottom: 357)
            let limit = PastedImagePreview.limit(for: anchor, in: Self.paneSize)
            let image = try await render(
                Scene(theme: theme, rows: screen(prompt: "\u{276F} ")) {
                    PastedImagePreview(
                        theme: theme, number: 12, image: wide.thumbnail, limit: limit, flash: nil,
                        onQuickLook: {}, onOpen: {}, onReveal: {}
                    )
                    .offset(x: 20, y: 20)
                    PastedImagePreview(
                        theme: theme, number: 3, image: small.thumbnail, limit: limit, flash: .open,
                        onQuickLook: {}, onOpen: {}, onReveal: {}
                    )
                    .offset(x: 540, y: 20)
                },
                name: "preview-\(name)")
            try assertPixel(image, at: CGPoint(x: 24, y: 60), is: theme.confirmCardColors.ground, "\(name) preview")

            let model = model(on: FakePane(), store: store())
            model.dropLabel = PaneDropLabel.text(count: 3, allImages: true)
            _ = try await render(
                Scene(theme: theme, rows: screen(prompt: "\u{276F} ")) { self.overlay(model, theme: theme) },
                name: "drop-\(name)")
        }
    }

    private func XCTUnwrapped<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
}
