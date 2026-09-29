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

    func testTheBundleBinaryLaunchesTheAppUnlessACommandIsNamed() {
        XCTAssertNil(FlockCommand.parse(invokedAs: "Flock", linkName: "flock", arguments: []))
        XCTAssertNil(FlockCommand.parse(invokedAs: "Flock", linkName: "flock", arguments: ["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertEqual(FlockCommand.parse(invokedAs: "Flock", linkName: "flock", arguments: ["release"]), .release)
    }

    func testTheInstalledLinkIsAlwaysACommand() {
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock", linkName: "flock", arguments: []), .help)
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock-dev", linkName: "flock-dev", arguments: ["--help"]), .help)
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock", linkName: "flock", arguments: ["relase"]), .unknown("relase"))
    }

    func testUsageListsEveryCommand() {
        let usage = FlockCommand.usage(name: "flock")
        XCTAssertTrue(usage.hasPrefix("usage: flock <command>"))
        for command in FlockCommand.summaries { XCTAssertTrue(usage.contains("  \(command.name)")) }
    }

    func testAFileFlockDidNotPutThereOffersNoAction() {
        XCTAssertNil(CommandLineTool.actionTitle(for: .otherFile))
        XCTAssertEqual(CommandLineTool.actionTitle(for: .otherLink(target: "/Old/Flock")), "Replace")
    }
}
