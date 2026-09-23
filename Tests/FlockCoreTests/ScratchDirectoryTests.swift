import XCTest
@testable import FlockCore

final class ScratchDirectoryTests: XCTestCase {
    func testTheDirectoryIsOwnerOnlyInsideTheTempDirectory() throws {
        let url = ScratchDirectory.url
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPaneChannelsMakeTheirFifosInTheScratchDirectory() throws {
        let directory = ScratchDirectory.url.standardizedFileURL.path
        let control = try XCTUnwrap(PaneControlChannel())
        let status = try XCTUnwrap(PaneStatusChannel())
        XCTAssertEqual(URL(fileURLWithPath: control.path).deletingLastPathComponent().standardizedFileURL.path, directory)
        XCTAssertEqual(URL(fileURLWithPath: status.path).deletingLastPathComponent().standardizedFileURL.path, directory)
    }
}
