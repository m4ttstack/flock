import XCTest
@testable import FlockCore

final class WorkspaceSymbolsTests: XCTestCase {
    func testTheSetIsDistinctSymbolsWithTitlesInNamedGroups() {
        let all = WorkspaceSymbols.all
        XCTAssertTrue((150...300).contains(all.count), "\(all.count)")
        XCTAssertFalse(WorkspaceSymbols.groups.contains { $0.title.isEmpty || $0.symbols.isEmpty })
        XCTAssertEqual(Set(all.map(\.name)).count, all.count)
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
        XCTAssertFalse(all.contains { $0.title.isEmpty })
    }

    func testNoSymbolReadsAsStatus() {
        let statusShapes = ["check", "exclamation", "clock", "bell", "xmark", "circle", "dot", "timer", "alarm", "stop", "play", "pause"]
        for symbol in WorkspaceSymbols.all {
            for shape in statusShapes {
                XCTAssertFalse(symbol.name.contains(shape), "\(symbol.name) contains \(shape)")
            }
        }
    }

    func testASearchKeepsTheGroupsWhoseSymbolsMatchByTitleOrName() {
        XCTAssertEqual(WorkspaceSymbols.groups(matching: "  ").map(\.title), WorkspaceSymbols.groups.map(\.title))
        let database = WorkspaceSymbols.groups(matching: "DATA")
        XCTAssertEqual(database.flatMap(\.symbols).map(\.name), ["cylinder.fill"])
        XCTAssertEqual(database.map(\.title), ["Engineering"])
        let byName = WorkspaceSymbols.groups(matching: "cylinder").flatMap(\.symbols).map(\.name)
        XCTAssertEqual(byName, ["cylinder.fill", "cylinder.split.1x2.fill"])
        XCTAssertTrue(WorkspaceSymbols.groups(matching: "zzzz").isEmpty)
    }

    func testSearchingAGroupsTitleKeepsTheWholeGroup() throws {
        let engineering = try XCTUnwrap(WorkspaceSymbols.groups.first { $0.title == "Engineering" })
        XCTAssertEqual(WorkspaceSymbols.groups(matching: "engineering").first?.symbols, engineering.symbols)
    }

    func testContainsOnlyTheSetsOwnNames() {
        XCTAssertTrue(WorkspaceSymbols.contains("leaf.fill"))
        XCTAssertFalse(WorkspaceSymbols.contains("checkmark.circle.fill"))
        XCTAssertFalse(WorkspaceSymbols.contains(""))
    }
}
