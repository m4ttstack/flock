import XCTest
@testable import FlockCore

final class PaletteSurfaceTests: XCTestCase {
    func testTheClosedGridIsWorkspacesWhateverOverviewLastShowed() {
        XCTAssertEqual(
            PaletteSurface.current(gridShown: false, shownMode: .missionControl, paneShownInOverview: true), .workspaces
        )
    }

    func testOverviewIsTheBoardUntilAPaneIsOpened() {
        XCTAssertEqual(PaletteSurface.current(gridShown: true, shownMode: .missionControl, paneShownInOverview: false), .overview)
        XCTAssertEqual(
            PaletteSurface.current(gridShown: true, shownMode: .missionControl, paneShownInOverview: true), .overviewPane
        )
    }

    /// Arrange draws tiles, never the pane Overview had open.
    func testArrangeIsArrangeEvenWithAPaneRemembered() {
        XCTAssertEqual(PaletteSurface.current(gridShown: true, shownMode: .arrange, paneShownInOverview: true), .arrange)
    }

    func testThePaletteOpensOnlyWhereAPaneIsOnScreen() {
        XCTAssertEqual(PaletteSurface.allCases.filter(\.opensPalette), [.workspaces, .overviewPane])
    }

    func testEachViewTabNamesItsOwnSurfaces() {
        XCTAssertEqual(PaletteSurface.surfaces(of: .workspaces), [.workspaces])
        XCTAssertEqual(PaletteSurface.surfaces(of: .overview), [.overview, .overviewPane])
        XCTAssertEqual(PaletteSurface.surfaces(of: .arrange), [.arrange])
    }
}
