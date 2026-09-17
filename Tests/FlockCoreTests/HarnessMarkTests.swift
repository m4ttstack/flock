import CoreGraphics
import XCTest
@testable import FlockCore

/// The SVG path decoder the harness marks are drawn from, and the tie between
/// the path data compiled into the app and the source files it came from.
final class HarnessMarkTests: XCTestCase {
    // MARK: - the decoder

    func testAbsoluteLineCommandsTraceTheirBox() throws {
        let path = try XCTUnwrap(VectorMarkPath.cgPath(fromSVGPathData: "M0 0 H10 V10 H0 Z"))
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    /// Coordinates that follow a moveto with no command letter of their own
    /// are a polyline, and both bundled marks rely on the same implicit
    /// repeat for their other commands.
    func testCoordinatesAfterAMovetoAreLines() throws {
        let path = try XCTUnwrap(VectorMarkPath.cgPath(fromSVGPathData: "M0 0 10 0 10 10 Z"))
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testNumbersSeparatedOnlyByTheirOwnSignAreTwoNumbers() throws {
        let path = try XCTUnwrap(VectorMarkPath.cgPath(fromSVGPathData: "M0 0L10-5Z"))
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: -5, width: 10, height: 5))
    }

    func testCubicsAreFollowed() throws {
        let path = try XCTUnwrap(VectorMarkPath.cgPath(fromSVGPathData: "M0 0C0 10 10 10 10 0Z"))
        XCTAssertEqual(path.boundingBoxOfPath.width, 10, accuracy: 0.001)
        XCTAssertGreaterThan(path.boundingBoxOfPath.height, 0, "the curve never left the x axis")
    }

    /// A mark whose data the decoder does not fully read must come back as
    /// nothing, so the caller shows a monogram rather than a partial glyph.
    func testUnreadableDataIsRefusedRatherThanPartlyDrawn() {
        for data in [
            "M0 0 l10 0",                    // relative lineto
            "M0 0 A5 5 0 0 1 10 0",          // arc
            "M0 0 Q5 5 10 0",                // quadratic
            "10 0 20 0",                     // coordinates with no command
            "Z",                             // a close with nothing to close
            "M0 0 H",                        // a command missing its number
            "",
        ] {
            XCTAssertNil(VectorMarkPath.cgPath(fromSVGPathData: data), data)
        }
    }

    // MARK: - the marks themselves

    /// A mark that decoded down to a sliver, or ran outside the document it
    /// was drawn in, would still be non-nil; both would render as a smear.
    func testBothBundledMarksDecodeToARoughlySquareGlyphInsideTheirDocument() throws {
        for (name, mark) in [("claude", HarnessMark.claude), ("codex", HarnessMark.codex)] {
            let path = try XCTUnwrap(mark.cgPath, name)
            let box = path.boundingBoxOfPath
            let document = try Self.viewBox(ofSVGNamed: name)
            XCTAssertTrue(document.insetBy(dx: -1, dy: -1).contains(box), "\(name) \(box) is outside \(document)")
            XCTAssertGreaterThan(box.width, document.width * 0.4, name)
            XCTAssertGreaterThan(box.height, document.height * 0.4, name)
            XCTAssertEqual(box.width / box.height, 1, accuracy: 0.2, "\(name) is not a roughly square glyph")
        }
    }

    /// The compiled path data is a copy of the vendor's file, so the file is
    /// the record of where it came from only while the two agree. Whitespace
    /// is normalized because the literal is wrapped to stay readable.
    func testTheCompiledPathDataMatchesTheSourceSVGs() throws {
        for (name, mark) in [("claude", HarnessMark.claude), ("codex", HarnessMark.codex)] {
            let svg = try String(contentsOf: Self.svgURL(name), encoding: .utf8)
            let fromFile = try XCTUnwrap(Self.pathData(inSVG: svg), "no single path in \(name).svg")
            XCTAssertEqual(Self.normalized(mark.pathData), Self.normalized(fromFile), name)
        }
    }

    /// The `viewBox` the file declares, as a rect.
    private static func viewBox(ofSVGNamed name: String) throws -> CGRect {
        let svg = try String(contentsOf: svgURL(name), encoding: .utf8)
        guard let opening = svg.range(of: "viewBox=\""),
              let closing = svg[opening.upperBound...].firstIndex(of: "\"")
        else { throw MarkFixtureError.noViewBox(name) }
        let numbers = svg[opening.upperBound..<closing].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard numbers.count == 4 else { throw MarkFixtureError.noViewBox(name) }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private enum MarkFixtureError: Error {
        case noViewBox(String)
    }

    private static func svgURL(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent("Sources/Flock/Resources/HarnessMarks/\(name).svg")
    }

    private static func pathData(inSVG svg: String) -> String? {
        guard let opening = svg.range(of: " d=\"") else { return nil }
        guard let closing = svg[opening.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(svg[opening.upperBound..<closing])
    }

    private static func normalized(_ data: String) -> String {
        data.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
