import XCTest

/// The app's blanket subscription can die inside the bootstrap window: after
/// herdr acked it, before the snapshot that follows lands. The end of that
/// connection is the only thing that reports it, so an app that misses it goes
/// on drawing a session it can no longer hear about, with only the periodic
/// re-snapshot behind it -- minutes wide in production.
///
/// The fault is injected by `ScratchSession`'s fault proxy, a relay the app is
/// launched against instead of the session socket: nothing an outside process
/// can do reaches one connection of a running app, and stopping the server
/// takes every connection at once, which is the failure the app already
/// handles.
final class SubscriptionLossTests: XCTestCase {
    private var session: ScratchSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try ScratchSession.attachFromEnvironment()
        try session.reseed()
    }

    /// Longer than this case can possibly run. The wrapper gives the suite a
    /// two-second re-snapshot interval, under which the frozen mirror this
    /// case is about would be repaired by the next periodic replacement and
    /// the convergence below would succeed either way.
    private static let noResnapshotWithin = "600"

    @MainActor
    func testAppConvergesAfterItsSubscriptionIsCutDuringBootstrap() throws {
        let ids = session.seedIDs()
        let proxy = try session.startFaultProxy()
        // Armed before the launch, because the launch is what opens the
        // window: the app subscribes, snapshots and goes live in milliseconds.
        try session.armSubscriptionCut()

        // Registered before the launch that needs it, and capturing nothing:
        // an assertion failure under `continueAfterFailure = false` unwinds
        // this method through Objective-C, where a `defer` is not reliable.
        addTeardownBlock { await MainActor.run { XCUIApplication().terminate() } }
        let app = XCUIApplication.flock(
            socket: proxy,
            env: ["FLOCK_RESNAPSHOT_SECONDS": Self.noResnapshotWithin]
        )

        XCTAssertTrue(
            app.flockElement("flock.canvas.pane.\(ids.p1)").waitForExistence(timeout: 60),
            "the canvas never showed \(ids.p1), so the app never finished the bootstrap the cut lands inside"
        )
        // The fault has to have fired, or everything below it proves nothing:
        // an arm that never matched leaves an ordinary launch.
        assertEventually("the proxy cuts the app's subscription") {
            ((try? self.session.faultProxyCutCount()) ?? 0) >= 1
        } describing: {
            "the proxy reports \((try? self.session.faultProxyCutCount()).map(String.init) ?? "no") cut(s), "
                + "so the app's bootstrap never reached the snapshot the cut rides on"
        }

        // A change made outside the app, which can only reach the window over
        // a live subscription.
        try session.mutate(
            #"{"id":"e2e-split","method":"pane.split","params":{"target_pane_id":"\#(ids.p1)","direction":"down"}}"#
        )
        let after = try session.snapshot()
        let added = try XCTUnwrap(
            after.paneIDs(inTab: ids.tabA).first { $0 != ids.p1 && $0 != ids.p2 },
            "the split this test asserts on never landed in herdr"
        )

        XCTAssertTrue(
            app.flockElement("flock.canvas.pane.\(added)").waitForExistence(timeout: 30),
            "the canvas never showed \(added): the app is still live on the subscription the proxy cut"
        )
    }
}
