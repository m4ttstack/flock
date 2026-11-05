import XCTest
@testable import FlockCore

/// The marker is read straight out of the binary's bytes, never by running
/// it, so these fixtures are synthetic byte blobs rather than real herdr
/// checkouts.
final class HerdrMouseVerbsTests: XCTestCase {
    func testAbsentWhenTheMarkerIsNowhereInTheBytes() {
        let data = Data("some unrelated binary contents".utf8)

        XCTAssertFalse(HerdrMouseVerbs.present(in: data))
    }

    func testPresentWhenTheCaptureVerbAppears() {
        let data = Data("...terminal.mouse_capture...".utf8)

        XCTAssertTrue(HerdrMouseVerbs.present(in: data))
    }

    /// Stock herdr 0.9.2: it accepts inbound `terminal.mouse` but never
    /// reports capture, so it is not mouse support flock can use.
    func testInboundMouseVerbAloneIsAbsent() {
        let data = Data("terminal.inputterminal.resizeterminal.scrollterminal.mouseterminal.release".utf8)

        XCTAssertFalse(HerdrMouseVerbs.present(in: data))
    }

    func testEmptyDataIsAbsent() {
        XCTAssertFalse(HerdrMouseVerbs.present(in: Data()))
    }

    private func machO(cpuType: UInt32, body: String) -> Data {
        var header: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
        header += withUnsafeBytes(of: cpuType.littleEndian, Array.init)
        return Data(header) + Data(body.utf8)
    }

    func testAnIntelBuildCarriesTheVerbAsImmediateChunks() {
        let patched = machO(cpuType: 0x0100_0007, body: "\u{48}\u{B8}terminal\u{48}\u{B8}.mouse_c\u{48}\u{B8}apture")

        XCTAssertTrue(HerdrMouseVerbs.present(in: patched))
    }

    func testAStockIntelBuildIsAbsent() {
        let stock = machO(cpuType: 0x0100_0007, body: "terminal.mouseterminal.resizemouse_capture = true")

        XCTAssertFalse(HerdrMouseVerbs.present(in: stock))
    }

    /// The chunk counts only in an Intel binary, where the whole string
    /// cannot appear.
    func testAnAppleSiliconBuildNeedsTheWholeVerb() {
        XCTAssertFalse(HerdrMouseVerbs.present(in: machO(cpuType: 0x0100_000C, body: "x.mouse_cy")))
        XCTAssertTrue(HerdrMouseVerbs.present(in: machO(cpuType: 0x0100_000C, body: "terminal.mouse_capture")))
    }
}
