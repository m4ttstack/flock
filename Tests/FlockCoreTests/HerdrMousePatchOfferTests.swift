import XCTest

@testable import FlockCore

final class HerdrMousePatchOfferTests: XCTestCase {
    private let version = HerdrMousePatchVersion.supported

    func testPatchableWithNoDismissalIsOffered() {
        XCTAssertTrue(
            HerdrMousePatchOffer.shouldOffer(
                state: .patchable(installPath: "/usr/local/bin/herdr"), dismissedForVersion: nil
            )
        )
    }

    /// The five states with nothing to act on. Offering in any of them would
    /// put a banner in front of someone with no button behind it.
    func testEveryStateWithNothingToActOnIsSilent() {
        let silent: [HerdrMousePatchRowState] = [
            .supportedByHerdr,
            .installed(backupPath: "/usr/local/bin/herdr.flock-backup"),
            .artifactUnavailable(installPath: "/usr/local/bin/herdr"),
            .notWritable(installPath: "/usr/local/bin/herdr"),
            .unsupportedVersion,
        ]
        for state in silent {
            XCTAssertFalse(
                HerdrMousePatchOffer.shouldOffer(state: state, dismissedForVersion: nil),
                "expected no offer for \(state)"
            )
        }
    }

    /// Detection has not answered yet. Nothing is known, so nothing is
    /// claimed... a nil state must not read as "patchable".
    func testUnknownStateIsSilent() {
        XCTAssertFalse(HerdrMousePatchOffer.shouldOffer(state: nil, dismissedForVersion: nil))
    }

    func testDismissalForThisVersionSilencesIt() {
        XCTAssertFalse(
            HerdrMousePatchOffer.shouldOffer(
                state: .patchable(installPath: "/usr/local/bin/herdr"), dismissedForVersion: version
            )
        )
    }

    /// The reason the dismissal is keyed on a version rather than being a
    /// permanent "never": saying no to patching the herdr you have now says
    /// nothing about the one you install next, and that upgrade is when the
    /// offer becomes worth making again.
    func testDismissalForAnotherVersionDoesNotSilenceIt() {
        XCTAssertTrue(
            HerdrMousePatchOffer.shouldOffer(
                state: .patchable(installPath: "/usr/local/bin/herdr"),
                dismissedForVersion: "0.0.1-something-else"
            )
        )
    }

    /// A dismissal never reaches a state that was not going to offer anyway,
    /// so it cannot be what makes one of them speak up later.
    func testDismissalDoesNotResurrectASilentState() {
        XCTAssertFalse(
            HerdrMousePatchOffer.shouldOffer(state: .unsupportedVersion, dismissedForVersion: version)
        )
    }
}
