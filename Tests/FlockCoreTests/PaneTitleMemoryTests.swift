import XCTest
@testable import FlockCore

private struct IdleCommandClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data() }
}

@MainActor
final class PaneTitleMemoryTests: XCTestCase {
    /// `w1:t1`, an unnamed tab, holding one pane. A nil `session` leaves the
    /// pane without the field; a nil `title` or `label` leaves those out too.
    private func model(session: String? = "s1", title: String? = nil, label: String? = nil, sessionJSON: String? = nil) throws -> SessionModel {
        let sessionField = sessionJSON ?? session.map { #","agent_session":{"kind":"claude","value":"\#($0)"}"# } ?? ""
        let titleField = title.map { #","terminal_title_stripped":"\#($0)""# } ?? ""
        let labelField = label.map { #","label":"\#($0)""# } ?? ""
        let json = #"""
        {"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","label":"acme","number":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","number":1,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"idle","revision":0,"cwd":"/tmp"\#(sessionField)\#(titleField)\#(labelField)}],"layouts":[]}
        """#
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
    }

    private func tabTitle(_ model: SessionModel) throws -> TabTitle {
        TabTitle.resolve(try XCTUnwrap(model.tabs[WorkspaceID(rawValue: "w1")]?.first), in: model)
    }

    private func isolatedDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "flock.tests.paneTitleMemory.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Memory

    func testRememberingReplacesTheSessionsTitle() {
        var memory = PaneTitleMemory()
        memory.remember(sessionID: "s1", title: "first")
        memory.remember(sessionID: "s1", title: "second")
        XCTAssertEqual(memory.title(for: "s1"), "second")
        XCTAssertNil(memory.title(for: "s2"))
    }

    func testAnEmptyTitleOrSessionIsNeverRemembered() {
        var memory = PaneTitleMemory()
        memory.remember(sessionID: "s1", title: "")
        memory.remember(sessionID: "", title: "title")
        XCTAssertEqual(memory, PaneTitleMemory())
    }

    func testTheCapEvictsTheLeastRecentlyRemembered() {
        var memory = PaneTitleMemory()
        for index in 0..<PaneTitleMemory.capacity {
            memory.remember(sessionID: "s\(index)", title: "t\(index)")
        }
        memory.remember(sessionID: "s0", title: "t0 again")
        memory.remember(sessionID: "extra", title: "extra title")
        XCTAssertNil(memory.title(for: "s1"), "the oldest after s0 was refreshed")
        XCTAssertEqual(memory.title(for: "s0"), "t0 again")
        XCTAssertEqual(memory.title(for: "extra"), "extra title")
        XCTAssertEqual(memory.count, PaneTitleMemory.capacity)
    }

    func testTheMemoryRoundTripsThroughJSON() throws {
        var memory = PaneTitleMemory()
        memory.remember(sessionID: "s1", title: "one")
        memory.remember(sessionID: "s2", title: "two")
        let decoded = try JSONDecoder().decode(PaneTitleMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
        XCTAssertEqual(decoded.title(for: "s2"), "two")
    }

    // MARK: Fallback order

    func testALabelBeatsATitleBeatsTheMemoryBeatsShell() throws {
        var memory = PaneTitleMemory()
        memory.remember(sessionID: "s1", title: "remembered")

        let labelled = memory.applying(to: try model(title: "live", label: "release"))
        XCTAssertEqual(try tabTitle(labelled).text, "release")

        let titled = memory.applying(to: try model(title: "live"))
        XCTAssertEqual(try tabTitle(titled).text, "live")

        let untitled = memory.applying(to: try model())
        XCTAssertEqual(try tabTitle(untitled), TabTitle(text: "remembered", isFromPane: true))

        let unknownSession = memory.applying(to: try model(session: "other"))
        XCTAssertEqual(try tabTitle(unknownSession).text, "shell")

        let noSession = memory.applying(to: try model(session: nil))
        XCTAssertEqual(try tabTitle(noSession).text, "shell")
    }

    func testAPaneWithNoMemoryIsUnchangedByApplying() throws {
        let model = try model(title: "live")
        XCTAssertEqual(PaneTitleMemory().applying(to: model), model)
    }

    func testObservingRemembersOnlyAPaneWithASessionAndATitle() throws {
        var memory = PaneTitleMemory()
        XCTAssertFalse(memory.observe(try model(session: nil, title: "no session")))
        XCTAssertFalse(memory.observe(try model()))
        XCTAssertTrue(memory.observe(try model(title: "live")))
        XCTAssertEqual(memory.title(for: "s1"), "live")
    }

    func testObservingTheSameTitleAgainChangesNothing() throws {
        var memory = PaneTitleMemory()
        XCTAssertTrue(memory.observe(try model(title: "live")))
        XCTAssertFalse(memory.observe(try model(title: "live")))
        XCTAssertTrue(memory.observe(try model(title: "newer")), "a title herdr reports always refreshes the memory")
        XCTAssertEqual(memory.title(for: "s1"), "newer")
    }

    // MARK: Wire

    func testTheSessionIDComesFromAgentSessionValue() throws {
        let model = try model(session: "abc-123")
        XCTAssertEqual(model.panes[PaneID(rawValue: "w1:p1")]?.agentSessionID, "abc-123")
    }

    func testAMissingOrOddlyShapedAgentSessionNeverBreaksTheSnapshot() throws {
        XCTAssertNil(try model(session: nil).panes[PaneID(rawValue: "w1:p1")]?.agentSessionID)
        XCTAssertNil(try model(sessionJSON: #","agent_session":null"#).panes[PaneID(rawValue: "w1:p1")]?.agentSessionID)
        XCTAssertNil(try model(sessionJSON: #","agent_session":{"kind":"claude"}"#).panes[PaneID(rawValue: "w1:p1")]?.agentSessionID)
        XCTAssertEqual(try model(sessionJSON: #","agent_session":"plain""#).panes[PaneID(rawValue: "w1:p1")]?.agentSessionID, "plain")
    }

    // MARK: Store

    func testATitleSeenBeforeAHandoffShowsAfterIt() throws {
        let store = PaneTitleStore(userDefaults: nil)
        let before = store.apply(to: try model(title: "✳ Fixing tab sizes"))
        XCTAssertEqual(try tabTitle(before).text, "✳ Fixing tab sizes")

        let after = store.apply(to: try model())
        XCTAssertEqual(try tabTitle(after), TabTitle(text: "✳ Fixing tab sizes", isFromPane: true))
        XCTAssertEqual(after.panes[PaneID(rawValue: "w1:p1")]?.displayTitle, "✳ Fixing tab sizes")
    }

    func testANewTitleFromHerdrReplacesTheRememberedOne() throws {
        let store = PaneTitleStore(userDefaults: nil)
        _ = store.apply(to: try model(title: "old"))
        _ = store.apply(to: try model(title: "new"))
        XCTAssertEqual(try tabTitle(store.apply(to: try model())).text, "new")
    }

    func testTheMemorySurvivesALaunchThroughTheInjectedDefaults() throws {
        let defaults = try isolatedDefaults()
        let first = PaneTitleStore(userDefaults: defaults)
        _ = first.apply(to: try model(title: "kept across launches"))
        first.flush()

        let second = PaneTitleStore(userDefaults: defaults)
        XCTAssertEqual(try tabTitle(second.apply(to: try model())).text, "kept across launches")
    }

    func testNothingIsWrittenUntilTheMemoryChanges() throws {
        let defaults = try isolatedDefaults()
        let store = PaneTitleStore(userDefaults: defaults)
        _ = store.apply(to: try model(title: "live"))
        store.flush()
        XCTAssertNotNil(defaults.data(forKey: PaneTitleStore.defaultsKey))

        defaults.removeObject(forKey: PaneTitleStore.defaultsKey)
        _ = store.apply(to: try model(title: "live"))
        _ = store.apply(to: try model())
        store.flush()
        XCTAssertNil(defaults.data(forKey: PaneTitleStore.defaultsKey), "an unchanged memory is not written again")
    }

    func testAChangeIsWrittenOnceAfterTheDelayNotPerUpdate() async throws {
        let defaults = try isolatedDefaults()
        let store = PaneTitleStore(userDefaults: defaults, saveDelay: .milliseconds(20))
        for index in 0..<5 {
            _ = store.apply(to: try model(title: "title \(index)"))
        }
        XCTAssertNil(defaults.data(forKey: PaneTitleStore.defaultsKey), "coalesced: nothing written inside the delay")
        try await Task.sleep(for: .milliseconds(200))
        let data = try XCTUnwrap(defaults.data(forKey: PaneTitleStore.defaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(PaneTitleMemory.self, from: data).title(for: "s1"), "title 4")
    }

    func testAnUnreadableStoredValueStartsEmpty() throws {
        let defaults = try isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: PaneTitleStore.defaultsKey)
        let store = PaneTitleStore(userDefaults: defaults)
        XCTAssertEqual(try tabTitle(store.apply(to: try model())).text, "shell")
    }

    // MARK: View model

    func testTheViewModelShowsTheRememberedTitleOnceHerdrStopsReportingOne() throws {
        let defaults = try isolatedDefaults()
        let viewModel = SessionViewModel(client: IdleCommandClient(), paneTitleDefaults: defaults)
        viewModel.update(model: try model(title: "✳ Fixing tab sizes"), connection: .live)
        viewModel.update(model: try model(), connection: .live)
        let shown = try XCTUnwrap(viewModel.model)
        XCTAssertEqual(try tabTitle(shown).text, "✳ Fixing tab sizes")
        XCTAssertEqual(viewModel.fullModel?.panes[PaneID(rawValue: "w1:p1")]?.displayTitle, "✳ Fixing tab sizes")
    }
}
