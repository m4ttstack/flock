import XCTest
@testable import FlockCore

final class DevRebuildPlanTests: XCTestCase {
    func testTheCheckoutIsThreeLevelsAboveTheDevBundle() {
        XCTAssertEqual(DevRebuildPlan.checkout(forBundle: "/acme/flock/build/dev/Flock-dev.app"), "/acme/flock")
        XCTAssertEqual(DevRebuildPlan.checkout(forBundle: "/acme/flock/build/dev/Flock-dev.app/"), "/acme/flock")
    }

    func testABundleOutsideACheckoutsBuildFolderHasNoCheckout() {
        XCTAssertNil(DevRebuildPlan.checkout(forBundle: "/Applications/Flock-dev.app"))
        XCTAssertNil(DevRebuildPlan.checkout(forBundle: "/acme/flock/build/release/Flock.app"))
    }

    func testOnlyMainIsBuilt() {
        XCTAssertNil(DevRebuildPlan.refusal(branch: "main"))
        XCTAssertEqual(
            DevRebuildPlan.refusal(branch: "pin-cswap-account"),
            "Flock Dev builds from main, and the checkout is on pin-cswap-account."
        )
        XCTAssertEqual(DevRebuildPlan.refusal(branch: nil), "Flock Dev couldn't read the checkout's branch.")
    }

    func testProgressFollowsTheLastBuildsDurationAndHoldsShortOfDone() {
        XCTAssertEqual(DevRebuildPlan.progress(elapsed: 0, expected: 100), 0)
        XCTAssertEqual(DevRebuildPlan.progress(elapsed: 50, expected: 100), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DevRebuildPlan.progress(elapsed: 500, expected: 100), DevRebuildPlan.progressCeiling)
        XCTAssertEqual(DevRebuildPlan.progress(elapsed: 10, expected: 0), DevRebuildPlan.progressCeiling)
    }

    func testTheFirstRebuildExpectsTwoMinutes() {
        XCTAssertEqual(DevRebuildPlan.expectedDuration(last: nil), 120)
        XCTAssertEqual(DevRebuildPlan.expectedDuration(last: 75), 75)
    }
}
