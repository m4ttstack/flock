import XCTest
@testable import FlockCore

/// The merge that decides which directories flock resolves `herdr` and the
/// agent CLIs in, and the lookup that reads it.
final class UserPathTests: XCTestCase {
    private let launchdDefault = "/usr/bin:/bin:/usr/sbin:/sbin"
    private let profile = "/Users/m/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    // MARK: - The merge

    /// The defect itself: a GUI launch starts from launchd's PATH, and the
    /// directory every agent CLI lives in is only ever added by the profile.
    func testTheLaunchdDefaultGainsTheProfileDirectories() {
        let merged = UserPath.merged(inherited: launchdDefault, loginShell: profile)
        XCTAssertEqual(
            merged, "/usr/bin:/bin:/usr/sbin:/sbin:/Users/m/.local/bin:/opt/homebrew/bin"
        )
    }

    func testALoginShellWithNothingToAddLeavesThePathAsItWas() {
        XCTAssertEqual(
            UserPath.merged(inherited: launchdDefault, loginShell: launchdDefault), launchdDefault
        )
    }

    /// No answer at all: the shell failed to spawn, exited non-zero, or was
    /// still running when the probe gave up on it.
    func testNoAnswerLeavesTheInheritedPathExactlyAsItWas() {
        XCTAssertEqual(UserPath.merged(inherited: profile, loginShell: nil), profile)
    }

    /// An answer that is empty is the same as no answer, and must never blank
    /// the PATH the process already had.
    func testAnEmptyAnswerLeavesTheInheritedPathExactlyAsItWas() {
        XCTAssertEqual(UserPath.merged(inherited: profile, loginShell: ""), profile)
    }

    /// A shell launch inherits a PATH the profile does not reproduce (a
    /// worktree's own bin, an e2e harness's shim). Losing it would trade one
    /// silent failure for another.
    func testAnInheritedEntryTheLoginShellNeverMentionsSurvivesAndKeepsItsPlace() {
        let merged = UserPath.merged(
            inherited: "/scratch/bin:/usr/bin", loginShell: "/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertEqual(merged, "/scratch/bin:/usr/bin:/opt/homebrew/bin")
    }

    /// Inherited entries keep their precedence, so a launch that already had a
    /// good PATH runs exactly the binaries it ran before the merge existed.
    func testInheritedEntriesKeepTheirPrecedenceOverAddedOnes() {
        let merged = UserPath.merged(inherited: "/usr/bin", loginShell: "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(merged, "/usr/bin:/opt/homebrew/bin")
    }

    func testDuplicatesCollapseToTheirFirstAppearance() {
        let merged = UserPath.merged(
            inherited: "/usr/bin:/bin:/usr/bin", loginShell: "/bin:/opt/homebrew/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(merged, "/usr/bin:/bin:/opt/homebrew/bin")
    }

    /// An empty segment is POSIX's spelling of the current directory. flock
    /// resolves binaries it is about to run, so it drops them.
    func testEmptySegmentsAreDropped() {
        let merged = UserPath.merged(inherited: "/usr/bin::/bin:", loginShell: ":/opt/homebrew/bin")
        XCTAssertEqual(merged, "/usr/bin:/bin:/opt/homebrew/bin")
    }

    func testEveryInheritedEntrySurvivesEveryAnswer() {
        let answers = [nil, "", "/opt/homebrew/bin", launchdDefault, profile, ":::"]
        for answer in answers {
            let merged = UserPath.entries(UserPath.merged(inherited: profile, loginShell: answer))
            for entry in UserPath.entries(profile) {
                XCTAssertTrue(merged.contains(entry), "\(entry) was dropped for answer \(answer ?? "nil")")
            }
        }
    }

    /// The degenerate launch: nothing inherited at all. The shell's answer is
    /// then the whole PATH rather than an addition to one.
    func testAnEmptyInheritedPathTakesTheLoginShellsWhole() {
        XCTAssertEqual(UserPath.merged(inherited: "", loginShell: profile), profile)
    }

    // MARK: - The lookup

    func testResolveTakesTheFirstDirectoryHoldingTheBinary() {
        let present: Set<String> = ["/opt/homebrew/bin/herdr", "/Users/m/.local/bin/herdr"]
        XCTAssertEqual(
            UserPath.resolve("herdr", on: profile, isExecutable: { present.contains($0) }),
            "/Users/m/.local/bin/herdr"
        )
    }

    func testResolveSkipsADirectoryThatDoesNotHoldIt() {
        let present: Set<String> = ["/opt/homebrew/bin/herdr"]
        XCTAssertEqual(
            UserPath.resolve("herdr", on: profile, isExecutable: { present.contains($0) }),
            "/opt/homebrew/bin/herdr"
        )
    }

    func testResolveIsNilWhenNothingOnThePathHoldsIt() {
        XCTAssertNil(UserPath.resolve("herdr", on: profile, isExecutable: { _ in false }))
    }

    func testResolveOnAnEmptyPathIsNil() {
        XCTAssertNil(UserPath.resolve("herdr", on: "", isExecutable: { _ in true }))
    }

    // MARK: - Entries

    func testEntriesKeepOrderAndDropEmpties() {
        XCTAssertEqual(UserPath.entries(":/usr/bin::/bin:"), ["/usr/bin", "/bin"])
        XCTAssertEqual(UserPath.entries(""), [])
        XCTAssertEqual(UserPath.entries(":::"), [])
    }
}
