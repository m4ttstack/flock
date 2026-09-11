import XCTest

/// Step 1: prove a real scripted drag lands, 20 times in a row.
final class DragLoopUITests: XCTestCase {
    private let dropFile = "/tmp/spike-drop.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTwentyScriptedDragsLandTheDrop() throws {
        let app = XCUIApplication()
        app.launch()

        let source = app.otherElements["spike.drag.source"]
        let target = app.otherElements["spike.drag.target"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "source element never appeared")
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target element never appeared")

        var landed = 0
        for i in 0..<20 {
            // Remove any prior drop file first so a stale file from a
            // previous iteration can't be misread as this iteration's drop.
            try? FileManager.default.removeItem(atPath: dropFile)

            let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.3, thenDragTo: to)

            guard let data = waitForDropFile(timeout: 3) else {
                XCTFail("iteration \(i): no drop file written within timeout")
                continue
            }
            guard (try? JSONDecoder().decode(DropPointFixture.self, from: data)) != nil else {
                XCTFail("iteration \(i): drop file did not parse as JSON")
                continue
            }
            landed += 1
        }

        print("SPIKE_RESULT drags_landed=\(landed)/20")
        XCTAssertEqual(landed, 20, "expected 20/20 scripted drags to land the drop")
    }

    private func waitForDropFile(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: dropFile) { return data }
            usleep(20_000)
        }
        return nil
    }
}

private struct DropPointFixture: Decodable {
    let x: Double
    let y: Double
    let timestamp: Double
}
