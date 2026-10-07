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

    func testContainsOnlyTheSetsOwnNames() {
        XCTAssertTrue(WorkspaceSymbols.contains("leaf.fill"))
        XCTAssertFalse(WorkspaceSymbols.contains("checkmark.circle.fill"))
        XCTAssertFalse(WorkspaceSymbols.contains(""))
    }
}
