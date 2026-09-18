import Foundation
import XCTest

/// Clipboard image bytes only become pasteable once they have a path, and the
/// file that path names is the user's own screenshot: owner-only, in an
/// owner-only directory, and gone within a day.
final class ClipboardImageStagingTests: XCTestCase {
    private var staged: [String] = []

    override func tearDown() {
        for path in staged {
            try? FileManager.default.removeItem(atPath: path)
        }
        staged = []
        super.tearDown()
    }

    private func stage(_ data: Data, fileExtension: String = "png") -> String? {
        let path = ClipboardImageStaging.stage(data, fileExtension: fileExtension)
        if let path { staged.append(path) }
        return path
    }

    func testTheBytesAreReadableAtThePathItReturns() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let path = try XCTUnwrap(stage(bytes))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testTheStagedFileCarriesTheExtensionItWasStagedWith() throws {
        let path = try XCTUnwrap(stage(Data([0x47, 0x49, 0x46]), fileExtension: "gif"))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "gif")
    }

    /// Two pastes of the same screenshot are two pastes, so neither may land
    /// on the other's file.
    func testEachStageGetsItsOwnFile() throws {
        let bytes = Data([0x01, 0x02, 0x03])
        let first = try XCTUnwrap(stage(bytes))
        let second = try XCTUnwrap(stage(bytes))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))
    }

    func testAStagedFileIsReadableOnlyByItsOwner() throws {
        let path = try XCTUnwrap(stage(Data([0x01])))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testTheStagingDirectoryIsReachableOnlyByItsOwner() throws {
        _ = try XCTUnwrap(stage(Data([0x01])))
        let permissions = try FileManager.default
            .attributesOfItem(atPath: ClipboardImageStaging.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o700)
    }

    func testStagingSweepsAFileOlderThanTheMaximumAge() throws {
        _ = try XCTUnwrap(stage(Data([0x01])))
        let stale = ClipboardImageStaging.directory
            .appendingPathComponent("clipboard-stale-\(UUID().uuidString).png")
        XCTAssertTrue(FileManager.default.createFile(atPath: stale.path, contents: Data([0x00])))
        staged.append(stale.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ClipboardImageStaging.maximumAge - 60)],
            ofItemAtPath: stale.path
        )

        _ = try XCTUnwrap(stage(Data([0x02])))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testStagingLeavesAFileYoungerThanTheMaximumAgeAlone() throws {
        let earlier = try XCTUnwrap(stage(Data([0x01])))
        _ = try XCTUnwrap(stage(Data([0x02])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier))
    }
}
