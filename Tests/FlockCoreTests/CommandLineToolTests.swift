import XCTest
@testable import FlockCore

final class CommandLineToolTests: XCTestCase {
    private let me = "/Applications/Flock.app/Contents/MacOS/Flock"

    func testEachFlavorGetsItsOwnName() {
        XCTAssertEqual(CommandLineTool.name(bundleID: "dev.mattstack.Flock"), "flock")
        XCTAssertEqual(CommandLineTool.name(bundleID: "dev.mattstack.Flock.dev"), "flock-dev")
    }

    func testStateFromWhatIsAtThePath() {
        XCTAssertEqual(CommandLineTool.state(exists: false, linkTarget: nil, executablePath: me), .notInstalled)
        XCTAssertEqual(CommandLineTool.state(exists: true, linkTarget: me, executablePath: me), .installed)
        XCTAssertEqual(
            CommandLineTool.state(exists: true, linkTarget: "/Old/Flock", executablePath: me),
            .otherLink(target: "/Old/Flock")
        )
        XCTAssertEqual(CommandLineTool.state(exists: true, linkTarget: nil, executablePath: me), .otherFile)
    }

    func testAFileFlockDidNotPutThereOffersNoAction() {
        XCTAssertNil(CommandLineTool.actionTitle(for: .otherFile))
        XCTAssertEqual(CommandLineTool.actionTitle(for: .otherLink(target: "/Old/Flock")), "Replace")
    }
}
