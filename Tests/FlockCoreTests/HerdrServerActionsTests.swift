import XCTest
@testable import FlockCore

final class HerdrServerActionsTests: XCTestCase {
    private let home = "/Users/someone"

    private func entry(_ name: String, running: Bool, isDefault: Bool = false) -> HerdrSessionEntry {
        let socket = isDefault
            ? home + "/.config/herdr/herdr.sock"
            : home + "/.config/herdr/sessions/\(name)/herdr.sock"
        return HerdrSessionEntry(name: name, isRunning: running, socketPath: socket, isDefault: isDefault)
    }

    private func action(
        for entry: HerdrSessionEntry, current: String = "/tmp/elsewhere.sock", heldBy: @escaping (String) -> String? = { _ in nil }
    ) -> HerdrServerAction {
        HerdrServerActions.action(for: entry, currentSocket: current, home: home, heldBy: heldBy)
    }

    func testDefaultIsNeverOffered() {
        XCTAssertEqual(action(for: entry("default", running: true, isDefault: true)), .unavailable("herdr's own server"))
        XCTAssertEqual(action(for: entry("default", running: false, isDefault: true)), .unavailable("herdr's own server"))
    }

    func testTheCurrentServerIsNeverOffered() {
        let acme = entry("acme", running: true)
        XCTAssertEqual(
            action(for: acme, current: "~/.config/herdr/sessions/acme//herdr.sock", heldBy: { _ in "Flock" }),
            .unavailable("This Flock is on it")
        )
    }

    func testAServerAnotherFlockHoldsSaysWhere() {
        let review = entry("review", running: true)
        var asked: [String] = []
        let result = action(for: review, heldBy: { socket in
            asked.append(socket)
            return "Flock"
        })
        XCTAssertEqual(result, .unavailable("Open in Flock"))
        XCTAssertEqual(asked, [review.socketPath])
    }

    func testRunningGetsStopAndStoppedGetsDelete() {
        XCTAssertEqual(action(for: entry("acme", running: true)), .stop)
        XCTAssertEqual(action(for: entry("demo", running: false)), .delete)
    }

    func testStopConfirmationSaysWhatCloses() {
        XCTAssertEqual(
            HerdrServerActions.confirmationMessage(for: entry("acme", running: true), action: .stop, profiles: [], home: home),
            "Every pane and agent on it closes. This can't be undone."
        )
    }

    func testDeleteConfirmationNamesTheProfilesOnThatServer() {
        let demo = entry("demo", running: false)
        let base = "Its saved workspaces go. This can't be undone."
        func message(_ profiles: [(name: String, socketPath: String)]) -> String {
            HerdrServerActions.confirmationMessage(for: demo, action: .delete, profiles: profiles, home: home)
        }
        let other = (name: "Default", socketPath: home + "/.config/herdr/herdr.sock")
        XCTAssertEqual(message([]), base)
        XCTAssertEqual(message([other]), base)
        XCTAssertEqual(message([other, (name: "Demo", socketPath: demo.socketPath)]), base + " Used by Demo.")
        XCTAssertEqual(
            message([
                (name: "Demo", socketPath: demo.socketPath), other,
                (name: "Video", socketPath: "~/.config/herdr/sessions/demo/./herdr.sock"),
            ]),
            base + " Used by Demo, Video."
        )
    }

    func testAFailureReadsHerdrsErrorMessage() {
        let json = Data(#"{"error":{"code":"session_delete_failed","message":"session acme is running"}}"#.utf8)
        XCTAssertEqual(
            HerdrServerActions.failureMessage(stderr: json, fallback: "herdr couldn't delete \"acme\"."),
            "session acme is running"
        )
        XCTAssertEqual(
            HerdrServerActions.failureMessage(stderr: Data("  boom\n".utf8), fallback: "herdr couldn't stop \"acme\"."),
            "boom"
        )
        XCTAssertEqual(
            HerdrServerActions.failureMessage(stderr: Data(" \n".utf8), fallback: "herdr couldn't stop \"acme\"."),
            "herdr couldn't stop \"acme\"."
        )
    }
}
