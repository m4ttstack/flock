import XCTest
@testable import FlockCore

final class CommandLineToolTests: XCTestCase {
    private let flocks: Set<String> = [
        "/Applications/Flock.app/Contents/MacOS/Flock",
        "/Users/someone/flock/build/dev/Flock-dev.app/Contents/MacOS/Flock-dev",
    ]

    private func state(exists: Bool, linkTarget: String?) -> CommandLineToolState {
        CommandLineTool.state(exists: exists, linkTarget: linkTarget, isFlock: flocks.contains)
    }

    func testStateFromWhatIsAtThePath() {
        XCTAssertEqual(state(exists: false, linkTarget: nil), .notInstalled)
        XCTAssertEqual(state(exists: true, linkTarget: "/Old/Flock"), .otherLink(target: "/Old/Flock"))
        XCTAssertEqual(state(exists: true, linkTarget: nil), .otherFile)
    }

    func testALinkToEitherFlavorIsInstalled() {
        for flock in flocks { XCTAssertEqual(state(exists: true, linkTarget: flock), .installed) }
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
