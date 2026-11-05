import AppKit
import FlockCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

private actor FaceScript {
    private var answers: [ChatFaceLoad]
    private(set) var calls = 0

    init(_ answers: [ChatFaceImage?]) { self.answers = answers.map { $0.map(ChatFaceLoad.face) ?? .noFace } }
    init(loads: [ChatFaceLoad]) { answers = loads }

    func next() -> ChatFaceLoad {
        calls += 1
        return answers.isEmpty ? .noFace : answers.removeFirst()
    }
}

/// The chip's face in a dark and a light theme, and how the store follows it.
/// PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ChatFaceTests: XCTestCase {
    private static let themes = [("dark", Theme(.tokyoNight)), ("light", Theme(.tokyoNightDay))]
    private static let inset: CGFloat = 12

    private static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    private func store(_ script: FaceScript, pause: @escaping (Duration) async throws -> Void) -> ChatStore {
        ChatStore(
            toasts: ToastCenter(), probe: { nil }, pause: pause,
            loadFace: { _ in await script.next() }, defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }

    func testAFinalFaceIsAskedForOnce() async throws {
        let face = ChatFaceImage(image: try Self.solid(1, 0, 0), zoom: 1, isFinal: true)
        let script = FaceScript([face])
        let store = store(script) { _ in XCTFail("a final face never waits") }
        await store.followFace("ivy.a1b2")
        await store.followFace("ivy.a1b2")
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(store.face(for: "ivy.a1b2"))
    }

    func testAFailedAskIsTriedAgain() async throws {
        let face = ChatFaceImage(image: try Self.solid(1, 0, 0), zoom: 1, isFinal: true)
        let script = FaceScript([nil, face])
        let store = store(script) { _ in }
        await store.followFace("ivy.a1b2")
        let calls = await script.calls
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(store.face(for: "ivy.a1b2"))
    }

    func testATemporaryFaceShowsUntilThePhotoArrives() async throws {
        let generated = ChatFaceImage(image: try Self.solid(0, 1, 0), zoom: 1, isFinal: false)
        let photo = ChatFaceImage(image: try Self.solid(0, 0, 1), zoom: 1, isFinal: true)
        let script = FaceScript([generated, nil, photo])
        var sawGenerated = false
        var store: ChatStore?
        store = self.store(script) { _ in sawGenerated = store?.face(for: "slack.u1")?.isFinal == false }
        await store?.followFace("slack.u1")
        XCTAssertTrue(sawGenerated)
        XCTAssertEqual(store?.face(for: "slack.u1")?.isFinal, true)
    }

    func testAChipLeftBehindKeepsFollowingWhenTheOtherGoes() async throws {
        let face = ChatFaceImage(image: try Self.solid(1, 0, 0), zoom: 1, isFinal: true)
        let script = FaceScript([nil, nil, nil, nil, face])
        let store = store(script) { _ in try await Task.sleep(for: .milliseconds(20)) }
        let leaving = Task { await store.followFace("ivy.a1b2") }
        let staying = Task { await store.followFace("ivy.a1b2") }
        try await Task.sleep(for: .milliseconds(5))
        leaving.cancel()
        await staying.value
        XCTAssertEqual(store.face(for: "ivy.a1b2")?.isFinal, true)
    }

    func testRetriesBackOffToFiveMinutes() async throws {
        let script = FaceScript([])
        var waits: [Duration] = []
        let store = store(script) { wait in
            waits.append(wait)
            if waits.count == 6 { throw CancellationError() }
        }
        await store.followFace("ivy.a1b2")
        XCTAssertEqual(waits, [.seconds(10), .seconds(30), .seconds(120), .seconds(300), .seconds(300), .seconds(300)])
    }

    func testAnRtWithoutTheVerbIsAskedOnceForEveryHandle() async {
        let script = FaceScript(loads: [.noVerb, .noVerb])
        let store = store(script) { _ in throw CancellationError() }
        await store.followFace("ivy.a1b2")
        await store.followFace("oak.c3d4")
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.face(for: "oak.c3d4"))
    }

    func testHandlesAppearingTogetherSendOneAskToAnRtWithoutTheVerb() async {
        let script = FaceScript(loads: [.noVerb, .noVerb, .noVerb])
        let store = ChatStore(
            toasts: ToastCenter(), probe: { nil }, pause: { _ in throw CancellationError() },
            loadFace: { _ in
                try? await Task.sleep(for: .milliseconds(30))
                return await script.next()
            },
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let first = Task { await store.followFace("ivy.a1b2") }
        let second = Task { await store.followFace("oak.c3d4") }
        let third = Task { await store.followFace("elm.e5f6") }
        _ = await (first.value, second.value, third.value)
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
    }

    func testAStopWhileWaitingEndsTheFollow() async throws {
        let script = FaceScript([])
        let store = store(script) { _ in throw CancellationError() }
        await store.followFace("ivy.a1b2")
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
    }

    func testAStoreWithNoFaceSourceAsksNothing() async {
        let store = ChatStore(toasts: ToastCenter(), probe: { nil }, pause: { _ in XCTFail("nothing to wait for") })
        await store.followFace("ivy.a1b2")
        XCTAssertNil(store.face(for: "ivy.a1b2"))
    }

    func testAPaddedSlackPhotoIsZoomedAndAGeneratedFaceIsNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("face.png")

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 480, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 60, y: 0, width: 360, height: 480))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let photo = try XCTUnwrap(ChatFaceImage.decode(ChatAvatar(kind: .slack, path: file.path), handle: "slack.u1"))
        // Scaling down softens the bar's edge by a pixel, so this sits just under 4/3.
        XCTAssertEqual(photo.zoom, 1.3, accuracy: 0.08)
        XCTAssertEqual(photo.image.width, ChatFaceImage.pixelSize)
        XCTAssertTrue(photo.isFinal)

        let generated = try XCTUnwrap(ChatFaceImage.decode(ChatAvatar(kind: .generated, path: file.path), handle: "slack.u1"))
        XCTAssertEqual(generated.zoom, 1)
        XCTAssertFalse(generated.isFinal)
    }

    private func writePNG(width: Int, height: Int, draw: (CGContext) -> Void) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("face.png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }

    func testAWidePhotoIsJudgedOnTheSquareTheChipShows() throws {
        let file = try writePNG(width: 640, height: 480) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 80, y: 0, width: 480, height: 480))
        }
        let photo = try XCTUnwrap(ChatFaceImage.decode(ChatAvatar(kind: .slack, path: file.path), handle: "slack.u1"))
        XCTAssertEqual(photo.zoom, 1)
        XCTAssertEqual(photo.image.width, photo.image.height)
    }

    func testHalfClearPaleBarsCountAsBars() throws {
        let file = try writePNG(width: 480, height: 480) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.5)
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
            context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 60, y: 0, width: 360, height: 480))
        }
        let photo = try XCTUnwrap(ChatFaceImage.decode(ChatAvatar(kind: .slack, path: file.path), handle: "slack.u1"))
        XCTAssertEqual(photo.zoom, 1.3, accuracy: 0.08)
    }

    func testAFileThatIsGoneDecodesToNil() {
        XCTAssertNil(ChatFaceImage.decode(ChatAvatar(kind: .slack, path: "/nonexistent/face.jpg"), handle: "slack.u1"))
    }

    func testTheChipDrawsTheFaceAndFallsBackToTheInitial() async throws {
        ChromeType.install()
        let face = ChatFaceImage(image: try Self.solid(1, 0, 1), zoom: 1, isFinal: true)
        for (scheme, theme) in Self.themes {
            let store = ChatStore(
                toasts: ToastCenter(), probe: { nil }, loadFace: { _ in .face(face) },
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )
            let withFace = try await render(theme: theme, store: store, handle: "ivy.a1b2", name: "\(scheme)-face")
            let withLetter = try await render(theme: theme, store: store, handle: nil, name: "\(scheme)-letter")
            let center = CGPoint(
                x: Double(withFace.pixelsWide) - (Self.inset + ChromeMetrics.PaneBar.chipFaceInset + ChromeMetrics.PaneBar.faceSize / 2) * 2,
                y: Double(withFace.pixelsHigh) / 2
            )
            let drawn = try XCTUnwrap(withFace.colorAt(x: Int(center.x), y: Int(center.y))?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(drawn.redComponent, 0.9, "\(scheme): the face fills its box")
            XCTAssertLessThan(drawn.greenComponent, 0.35, "\(scheme): the face fills its box")
            let letter = try XCTUnwrap(withLetter.colorAt(x: Int(center.x), y: Int(center.y))?.usingColorSpace(.sRGB))
            XCTAssertLessThan(letter.redComponent, 0.9, "\(scheme): no handle keeps the initial")
        }
    }

    private func render(theme: Theme, store: ChatStore, handle: String?, name: String) async throws -> NSBitmapImageRep {
        let pill = ChatHandlePill(theme: theme, name: "ivy", handle: handle, unread: 0).environment(store)
        let fitting = NSHostingView(rootView: pill).fittingSize
        let size = CGSize(width: fitting.width + 2 * Self.inset, height: fitting.height + 2 * Self.inset)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack { theme.pane; pill }.frame(width: size.width, height: size.height)
        )
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try snapshot(window)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat-face-\(name).png"))
        }
        window.close()
        return image
    }

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
}
