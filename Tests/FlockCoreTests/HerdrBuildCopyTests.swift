import XCTest

@testable import FlockCore

final class HerdrBuildCopyTests: XCTestCase {
    private let p = "/Users/nobody/.local/bin/herdr"

    func testBodies() {
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .missing(installPath: "/opt/herdr")), "Not installed. flock can install herdr to /opt/herdr.")
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .stock(installPath: p, installed: "0.9.5", newest: "0.9.5-ms.2")),
            "This herdr isn't the mattstack build, so clicks, scrolling and themes don't reach your panes. "
                + "flock can put herdr 0.9.5-ms.2 in its place.")
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .outdated(installPath: p, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2")),
            "herdr 0.9.5-ms.2 is available. flock can replace 0.9.5-ms.1 with it.")
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .outdated(installPath: p, installed: nil, newest: "0.9.5-ms.2")),
            "herdr 0.9.5-ms.2 is available. flock can replace this build with it.")
        XCTAssertEqual(HerdrBuildCopy.body(for: .current(version: "0.9.5-ms.2")), "Up to date.")
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .notWritable(installPath: "/opt/herdr")),
            "flock can't write to /opt/herdr from this account, so it leaves herdr alone.")
        XCTAssertEqual(
            HerdrBuildCopy.body(for: .listUnavailable(installed: nil)),
            "flock couldn't read the herdr build list, so it can't check for a newer build.")
        XCTAssertEqual(HerdrBuildCopy.heading, "herdr")
        XCTAssertEqual(HerdrBuildCopy.rowTitle, "mattstack build")
    }

    func testActionTitles() {
        XCTAssertEqual(HerdrBuildCopy.actionTitle(for: .missing(installPath: p)), "Install")
        XCTAssertEqual(HerdrBuildCopy.actionTitle(for: .stock(installPath: p, installed: nil, newest: "n")), "Install")
        XCTAssertEqual(HerdrBuildCopy.actionTitle(for: .outdated(installPath: p, installed: nil, newest: "n")), "Update")
        XCTAssertNil(HerdrBuildCopy.actionTitle(for: .current(version: "v")))
        XCTAssertNil(HerdrBuildCopy.actionTitle(for: .notWritable(installPath: p)))
        XCTAssertNil(HerdrBuildCopy.actionTitle(for: .listUnavailable(installed: nil)))
    }

    func testConfirmations() {
        XCTAssertEqual(
            HerdrBuildCopy.installConfirmation(installPath: "/opt/herdr", newest: "0.9.5-ms.2"),
            .init(
                title: "Install herdr 0.9.5-ms.2?",
                message: "flock will replace /opt/herdr with herdr 0.9.5-ms.2, the mattstack build, once its download matches the build list.",
                confirmButtonTitle: "Install"))
        XCTAssertEqual(
            HerdrBuildCopy.updateConfirmation(installPath: "/opt/herdr", newest: "0.9.5-ms.2"),
            .init(
                title: "Update herdr to 0.9.5-ms.2?",
                message: "flock will replace /opt/herdr with herdr 0.9.5-ms.2 once its download matches the build list.",
                confirmButtonTitle: "Update"))
    }

    func testRestartAndMissingAndErrorStrings() {
        XCTAssertEqual(HerdrBuildCopy.restartHeadline(for: .installed), "herdr is installed")
        XCTAssertEqual(HerdrBuildCopy.restartHeadline(for: .updated), "herdr is updated")
        XCTAssertEqual(HerdrBuildCopy.restartHeadline(for: .serverBehind), "herdr's server is out of date")
        XCTAssertEqual(HerdrBuildCopy.restartDetail(for: .serverBehind, restartsServer: true), "A restart keeps your panes running.")
        XCTAssertEqual(HerdrBuildCopy.restartDetail(for: .updated, restartsServer: true), "Restart herdr to finish; panes keep running.")
        XCTAssertEqual(HerdrBuildCopy.restartDetail(for: .installed), "Restart Flock so your panes pick it up.")
        XCTAssertEqual(HerdrBuildCopy.restartActionTitle(restartsServer: true), "Restart herdr")
        XCTAssertEqual(HerdrBuildCopy.restartActionTitle(restartsServer: false), "Restart Flock")
        XCTAssertEqual(HerdrBuildCopy.serverRestartProgressTitle, "Restarting herdr...")
        XCTAssertEqual(HerdrBuildCopy.missingHint, "flock can install the mattstack build of herdr for you.")
        XCTAssertEqual(HerdrBuildCopy.missingInstallTitle, "Install herdr")
        XCTAssertEqual(HerdrBuildCopy.missingInstallingTitle, "Installing herdr\u{2026}")
        XCTAssertEqual(HerdrBuildCopy.downloadFailed, "Couldn't download herdr. Check your connection and try again.")
        XCTAssertEqual(HerdrBuildCopy.checksumMismatch, "The download didn't match the build list. Nothing was changed.")
        XCTAssertEqual(HerdrBuildCopy.listUnreadable, "flock couldn't read the herdr build list. Check your connection and try again.")
        XCTAssertEqual(HerdrBuildCopy.herdrChanged, "herdr changed while the new build downloaded. Nothing was changed.")
        XCTAssertEqual(HerdrBuildCopy.notWritable, "herdr's install location is not writable.")
        XCTAssertEqual(HerdrBuildCopy.renameFailed, "The file move failed partway through.")
        XCTAssertEqual(
            HerdrBuildCopy.integrationFailed,
            "herdr is installed, but its Claude integration didn't install. Run herdr integration install claude in a terminal.")
        XCTAssertEqual(HerdrBuildCopy.pillTitle(newest: "0.9.5-ms.2"), "herdr 0.9.5-ms.2")
        XCTAssertEqual(HerdrBuildCopy.pillHelp, "A newer herdr is available. Open Settings to update.")
    }

    /// Settings installs from the build list; `herdr update` would install stock herdr.
    func testTheProtocolBannerPointsToSettings() {
        XCTAssertEqual(
            HerdrBuildCopy.protocolTooOld(found: 19, required: 22, onMachine: false),
            "herdr is too old for flock (found protocol 19, need 22). Update it in Settings.")
        XCTAssertEqual(
            HerdrBuildCopy.protocolTooOld(found: 19, required: 22, onMachine: true),
            "herdr is too old for flock (found protocol 19, need 22). Update herdr on that machine.")
        XCTAssertEqual(HerdrBuildCopy.protocolTooOldActionTitle, "Open Settings")
    }

    func testNoRestoreOrBackupWording() {
        let c = HerdrBuildCopy.self
        let all: [String] = [
            c.heading, c.rowTitle, c.restartActionTitle, c.serverRestartActionTitle, c.serverRestartProgressTitle,
            c.serverRestartConfirmation.title, c.serverRestartConfirmation.message, c.serverRestartFailedBanner,
            c.serverRestartFailure("x"), c.missingHint, c.missingInstallTitle, c.missingInstallingTitle,
            c.downloadFailed, c.checksumMismatch, c.listUnreadable, c.herdrChanged, c.notWritable, c.renameFailed,
            c.integrationFailed, c.pillHelp, c.pillTitle(newest: "n"),
            c.installConfirmation(installPath: p, newest: "n").message, c.updateConfirmation(installPath: p, newest: "n").message,
            c.restartDetail(for: .installed), c.restartDetail(for: .serverBehind),
            c.protocolTooOld(found: 19, required: 22, onMachine: false), c.protocolTooOld(found: 19, required: 22, onMachine: true),
            c.protocolTooOldActionTitle,
        ] + [
            HerdrBuildState.missing(installPath: p), .stock(installPath: p, installed: "a", newest: "n"),
            .outdated(installPath: p, installed: "a", newest: "n"), .current(version: "v"), .notWritable(installPath: p),
            .listUnavailable(installed: nil),
        ].map(c.body(for:))
        for text in all {
            for banned in ["Restore", "backup", "herdr.dev", "herdr update"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(text)")
            }
        }
    }
}
