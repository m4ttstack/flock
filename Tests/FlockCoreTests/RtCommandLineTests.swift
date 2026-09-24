import XCTest
@testable import FlockCore

final class RtCommandLineTests: XCTestCase {
    func testEachKindsLineCarriesItsRedirectAndTheStatusSuffix() {
        XCTAssertEqual(RtCommandLine.command(for: .nav, shell: .posix), #"command rt nav >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .glitter, shell: .posix), #"command rt glitter; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .run, shell: .posix), #"command rt run --resolve-only >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(RtCommandLine.command(for: .runner, shell: .posix), #"command rt runner --herdr; echo $? >"$FLOCK_RT_STATUS""#)
    }

    func testASeededRunnerReadsItsSeedFile() {
        XCTAssertEqual(
            RtCommandLine.command(for: .runner, shell: .posix, seeded: true),
            #"command rt runner --herdr --seed-file "$FLOCK_RT_SEED"; echo $? >"$FLOCK_RT_STATUS""#
        )
    }

    func testAFishShellGetsItsStatusVariable() {
        XCTAssertEqual(RtCommandLine.command(for: .glitter, shell: .fish), #"command rt glitter; echo $status >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(ShellFlavor(processName: "fish"), .fish)
        XCTAssertEqual(ShellFlavor(processName: "-fish"), .fish)
        XCTAssertEqual(ShellFlavor(processName: "zsh"), .posix)
        XCTAssertEqual(ShellFlavor(processName: nil), .posix)
    }

    func testPhaseTwoCdsIntoTheTargetThenRunsTheTemplate() {
        let result = RunResolveResult(targetDir: "/src/acme/web", packageLabel: "web", worktree: "/src/acme", branch: "main", commandTemplate: "pnpm run test", script: "test")
        XCTAssertEqual(RtCommandLine.phaseTwo(result, shell: .posix), #"cd '/src/acme/web' && pnpm run test; echo $? >"$FLOCK_RT_STATUS""#)
    }

    func testQuotingSurvivesASingleQuote() {
        XCTAssertEqual(RtCommandLine.quoted("/src/matt's app"), #"'/src/matt'\''s app'"#)
        XCTAssertEqual(RtCommandLine.cd("/src/matt's app"), #"cd '/src/matt'\''s app'"#)
    }
}
