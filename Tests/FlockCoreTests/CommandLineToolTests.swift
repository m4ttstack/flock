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
        XCTAssertNil(FlockCommand.parse(invokedAs: "Flock", arguments: []))
        XCTAssertNil(FlockCommand.parse(invokedAs: "Flock", arguments: ["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertEqual(FlockCommand.parse(invokedAs: "Flock", arguments: ["release"]), .release)
    }

    func testTheInstalledLinkIsAlwaysACommand() {
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock", arguments: []), .help)
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock-dev", arguments: ["--help"]), .help)
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock", arguments: ["relase"]), .unknown("relase"))
    }

    func testAttachPassesTheRestToHerdr() {
        XCTAssertEqual(FlockCommand.parse(invokedAs: "flock", arguments: ["attach"]), .attach([]))
        XCTAssertEqual(
            FlockCommand.parse(invokedAs: "flock", arguments: ["attach", "--session", "work"]),
            .attach(["--session", "work"])
        )
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
