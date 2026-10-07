import Foundation
import XCTest

/// Every chrome corner takes a `ChromeRadius` step, so a radius typed as a
/// number is a shape that has left the scale.
final class ChromeRadiusLiteralTests: XCTestCase {
    /// Icon geometry drawn inside a glyph's own box, not a chrome shape.
    private static let glyphRadii: Set<String> = [
        "static let cornerRadius: CGFloat = 4.75",
        "static let glyphCornerRadius: CGFloat = 1.5",
    ]

    private static let metricLiteral = try! NSRegularExpression(pattern: #"[cC]ornerRadius\w*: CGFloat = [0-9]"#)
    /// A zero radius is a square, which needs no step.
    private static let viewLiteral = try! NSRegularExpression(pattern: #"cornerRadius: (0*[1-9][0-9.]*|0\.[0-9]*[1-9])\b"#)

    func testNoChromeMetricHoldsALiteralCornerRadius() throws {
        let theme = Self.repositoryRoot.appendingPathComponent("Sources/Flock/Theme")
        let files = try Self.swiftFiles(under: theme).filter { $0.lastPathComponent.hasPrefix("ChromeMetrics") }
        XCTAssertFalse(files.isEmpty)
        let hits = try files.flatMap { file in
            try Self.matches(Self.metricLiteral, in: file).filter { !Self.glyphRadii.contains($0.text) }
        }
        XCTAssertEqual(hits.map(\.description), [], "use a ChromeRadius step")
    }

    func testNoViewDrawsALiteralCornerRadius() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources/Flock")
        let hits = try Self.swiftFiles(under: sources).flatMap { try Self.matches(Self.viewLiteral, in: $0) }
        XCTAssertEqual(hits.map(\.description), [], "use a ChromeRadius step")
    }

    private struct Hit {
        let file: String
        let line: Int
        let text: String
        var description: String { "\(file):\(line): \(text)" }
    }

    private static func matches(_ pattern: NSRegularExpression, in file: URL) throws -> [Hit] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        return lines.enumerated().compactMap { index, line in
            let range = NSRange(line.startIndex..., in: line)
            guard pattern.firstMatch(in: line, range: range) != nil else { return nil }
            return Hit(file: file.lastPathComponent, line: index + 1, text: line.trimmingCharacters(in: .whitespaces))
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "cannot read \(directory.path)"
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
