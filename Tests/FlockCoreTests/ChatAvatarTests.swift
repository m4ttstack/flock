import FlockCore
import XCTest

final class ChatAvatarTests: XCTestCase {
    func testAFaceDecodes() {
        let stdout = Data(#"{"ok":true,"kind":"slack","path":"/faces/a.jpg"}"#.utf8)
        XCTAssertEqual(ChatAvatar.decode(stdout: stdout, exitCode: 0), ChatAvatar(kind: .slack, path: "/faces/a.jpg"))
    }

    func testNoFaceDecodesToNil() {
        XCTAssertNil(ChatAvatar.decode(stdout: Data(#"{"ok":false,"error":"no face"}"#.utf8), exitCode: 1))
        XCTAssertNil(ChatAvatar.decode(stdout: Data(#"{"ok":false,"error":"no face"}"#.utf8), exitCode: 0))
        XCTAssertNil(ChatAvatar.decode(stdout: Data("usage: rt chat <join|leave> ...".utf8), exitCode: 0))
        XCTAssertNil(ChatAvatar.decode(stdout: Data(), exitCode: 2))
        XCTAssertNil(ChatAvatar.decode(stdout: Data(#"{"ok":true,"kind":"new","path":"/a"}"#.utf8), exitCode: 0))
    }

    func testUsageTextMeansNoVerbAndAnErrorMeansNoFace() {
        XCTAssertEqual(ChatAvatar.answer(stdout: Data("usage: rt chat <join|leave> ...".utf8), exitCode: 1), .noVerb)
        XCTAssertEqual(ChatAvatar.answer(stdout: Data(), exitCode: 2), .noVerb)
        XCTAssertEqual(ChatAvatar.answer(stdout: Data(#"{"ok":false,"error":"no face"}"#.utf8), exitCode: 1), .noFace)
        XCTAssertEqual(
            ChatAvatar.answer(stdout: Data(#"{"ok":true,"kind":"generated","path":"/a.png"}"#.utf8), exitCode: 0),
            .face(ChatAvatar(kind: .generated, path: "/a.png"))
        )
    }

    func testTheArgumentsAskForJSONAtASize() {
        XCTAssertEqual(
            ChatAvatar.arguments(handle: "ivy.a1b2", size: 48),
            ["chat", "avatar", "ivy.a1b2", "--size", "48", "--json"]
        )
    }

    func testOnlyASlackHandlesGeneratedFaceIsTemporary() {
        let generated = ChatAvatar(kind: .generated, path: "/a.png")
        let photo = ChatAvatar(kind: .slack, path: "/a.jpg")
        XCTAssertFalse(generated.isFinal(for: "slack.u1"))
        XCTAssertTrue(photo.isFinal(for: "slack.u1"))
        XCTAssertTrue(generated.isFinal(for: "ivy.a1b2"))
    }

    private func pixels(barWidth: Int, bar: UInt8 = 255, alpha: UInt8 = 255) -> [UInt8] {
        let size = ChatFaceZoom.sampleSize
        var rgba = [UInt8]()
        for _ in 0..<size {
            for x in 0..<size {
                let isBar = x < barWidth || x >= size - barWidth
                rgba += isBar ? [bar, bar, bar, alpha] : [40, 80, 120, 255]
            }
        }
        return rgba
    }

    func testAPhotoWithNoBarsIsNotZoomed() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 0)), 1)
    }

    func testBarsTooThinToMatterAreLeftAlone() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 2)), 1)
    }

    func testSideBarsZoomOutOfTheFrame() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 6)), 4.0 / 3.0, accuracy: 0.001)
    }

    func testClearBarsCountAsBars() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 6, bar: 0, alpha: 0)), 4.0 / 3.0, accuracy: 0.001)
    }

    func testTheZoomIsCapped() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 20)), 1.8)
    }

    func testAnAllBlankImageStaysInRange() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: pixels(barWidth: 24)), 1.8)
    }

    func testPixelsOfTheWrongSizeAreNotZoomed() {
        XCTAssertEqual(ChatFaceZoom.zoom(rgba: [1, 2, 3]), 1)
    }
}
