import FlockCore
import XCTest

extension HerdProgressSources {
    /// A machine without rt: every herd row counts herdr's panes, as every
    /// render that predates rt's count expects.
    static let unanswered = HerdProgressSources(listHerds: { nil }, readStatus: { _ in nil })
}

enum HerdProgressFixture {
    static let acme = "acme-sweep-20260922-081502"
    static let ci = "ci-sweep-20260922-112541"

    static func label(_ id: String) -> String { "herd: \(id)" }

    static func list(_ ids: [String]) -> Data {
        let rows = ids.map { #"{"id":"\#($0)","workspace":"herd: \#($0)","status":"active","jobs":2}"# }
        return Data(#"{"herds":[\#(rows.joined(separator: ","))]}"#.utf8)
    }

    static func status(_ jobs: [String]) -> Data {
        let rows = jobs.enumerated().map { #"{"name":"job-\#($0.offset)","status":"\#($0.element)"}"# }
        return Data(#"{"herd":{"id":"x"},"jobs":[\#(rows.joined(separator: ","))]}"#.utf8)
    }
}

/// Records every herd id asked about and answers from a fixed table.
private actor StatusLog {
    private let answers: [String: Data]
    private(set) var asked: [String] = []
    private(set) var lists = 0

    init(_ answers: [String: Data]) {
        self.answers = answers
    }

    func list(_ data: Data?) -> Data? {
        lists += 1
        return data
    }

    func status(_ id: String) -> Data? {
        asked.append(id)
        return answers[id]
    }
}

/// Answers each list call from a script, the last answer repeating.
private actor ListScript {
    private let answers: [Data?]
    private var calls = 0

    init(_ answers: [Data?]) {
        self.answers = answers
    }

    func next() -> Data? {
        defer { calls += 1 }
        return answers[min(calls, answers.count - 1)]
    }
}

@MainActor
final class HerdProgressStoreTests: XCTestCase {
    private typealias F = HerdProgressFixture

    private func store(list: Data?, statuses: [String: Data], log: StatusLog? = nil) -> (HerdProgressStore, StatusLog) {
        let log = log ?? StatusLog(statuses)
        let sources = HerdProgressSources(listHerds: { await log.list(list) }, readStatus: { await log.status($0) })
        return (HerdProgressStore(sources: sources), log)
    }

    func testEachHerdOnTheRailGetsRtsCountUnderItsWorkspaceLabel() async {
        let (store, _) = store(
            list: F.list([F.acme, F.ci]),
            statuses: [F.acme: F.status(["done", "active"]), F.ci: F.status(["closed", "done"])]
        )
        await store.refresh(labels: [F.label(F.acme), F.label(F.ci)])
        XCTAssertEqual(store.progress, [
            F.label(F.acme): HerdProgress(done: 1, total: 2, isRunning: true),
            F.label(F.ci): HerdProgress(done: 2, total: 2, isRunning: false),
        ])
    }

    /// rt lists every active herd on the machine, including ones in a hidden
    /// herdr session the rail never shows; those are not worth an `rt` call.
    func testOnlyHerdsTheRailShowsAreAsked() async {
        let (store, log) = store(list: F.list([F.acme, F.ci]), statuses: [F.acme: F.status(["done"])])
        await store.refresh(labels: [F.label(F.acme)])
        let asked = await log.asked
        XCTAssertEqual(asked, [F.acme])
        XCTAssertEqual(Array(store.progress.keys), [F.label(F.acme)])
    }

    /// A herd rt does not answer for keeps no entry, which is what sends its
    /// row back to counting herdr's panes.
    func testAHerdRtCannotAnswerForHasNoEntry() async {
        let (store, _) = store(list: F.list([F.acme, F.ci]), statuses: [F.acme: F.status(["done"])])
        await store.refresh(labels: [F.label(F.acme), F.label(F.ci)])
        XCTAssertNil(store.progress[F.label(F.ci)])
        XCTAssertNotNil(store.progress[F.label(F.acme)])
    }

    func testAFailedListKeepsTheLastAnswer() async {
        let lists = ListScript([F.list([F.acme]), nil])
        let log = StatusLog([F.acme: F.status(["done", "active"])])
        let store = HerdProgressStore(sources: HerdProgressSources(
            listHerds: { await lists.next() }, readStatus: { await log.status($0) }
        ))
        await store.refresh(labels: [F.label(F.acme)])
        let answered = store.progress
        XCTAssertFalse(answered.isEmpty)

        await store.refresh(labels: [F.label(F.acme)])
        XCTAssertEqual(store.progress, answered)
    }

    func testNoHerdsOnTheRailAsksRtNothing() async {
        let (store, log) = store(list: F.list([F.acme]), statuses: [F.acme: F.status(["done"])])
        await store.refresh(labels: [])
        let lists = await log.lists
        XCTAssertEqual(lists, 0)
        XCTAssertTrue(store.progress.isEmpty)
    }

    func testOverlappingRefreshesShareOneRound() async {
        let (store, log) = store(list: F.list([F.acme]), statuses: [F.acme: F.status(["done"])])
        async let one: Void = store.refresh(labels: [F.label(F.acme)])
        async let two: Void = store.refresh(labels: [F.label(F.acme)])
        _ = await (one, two)
        let lists = await log.lists
        XCTAssertEqual(lists, 1)
    }
}
