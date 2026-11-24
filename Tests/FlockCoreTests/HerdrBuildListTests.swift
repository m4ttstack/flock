import XCTest

@testable import FlockCore

final class HerdrBuildListTests: XCTestCase {
    static let sha1Arm = String(repeating: "a", count: 64)
    static let sha1X86 = String(repeating: "b", count: 64)
    static let sha2Arm = String(repeating: "c", count: 64)
    static let sha2X86 = String(repeating: "d", count: 64)
    static let patched = [String(repeating: "1", count: 64), String(repeating: "2", count: 64), String(repeating: "3", count: 64)]
    static let base = "https://github.com/m4ttstack/herdr/releases/download"

    static func json(
        schema: Int? = 1, newest: String = "0.9.5-ms.2", extraAsset: String = "", sha: String = sha2Arm,
        secondURL: String = "\(base)/v0.9.5-ms.2/herdr-macos-aarch64"
    ) -> String {
        let schemaField = schema.map { "\"schema\":\($0)," } ?? ""
        return """
            {\(schemaField)"newest":"\(newest)","builds":[
            {"version":"0.9.5-ms.1","herdr":"0.9.5","revision":1,"changesServer":true,"assets":{
              "arm64":{"url":"\(base)/v0.9.5-ms.1/herdr-macos-aarch64","sha256":"\(sha1Arm)"},
              "x86_64":{"url":"\(base)/v0.9.5-ms.1/herdr-macos-x86_64","sha256":"\(sha1X86)"}},
              "supersedes":[]},
            {"version":"0.9.5-ms.2","herdr":"0.9.5","revision":2,"changesServer":true,"assets":{
              "arm64":{"url":"\(secondURL)","sha256":"\(sha)"},
              "x86_64":{"url":"\(base)/v0.9.5-ms.2/herdr-macos-x86_64","sha256":"\(sha2X86)"}\(extraAsset)},
              "supersedes":["\(sha1Arm)","\(sha1X86)"]}],
            "flockPatchSha256":["\(patched[0])","\(patched[1])","\(patched[2])"]}
            """
    }

    private func decode(_ text: String) -> HerdrBuildList? { HerdrBuildList.decode(Data(text.utf8)) }

    func testDecodesManifestsOutput() throws {
        let list = try XCTUnwrap(decode(Self.json()))
        XCTAssertEqual(list.newest.version.display, "0.9.5-ms.2")
        XCTAssertEqual(list.newest.assets[.arm64]?.sha256, Self.sha2Arm)
        XCTAssertTrue(list.newest.changesServer)
        XCTAssertEqual(list.builds.count, 2)
        XCTAssertEqual(list.flockPatchSha256.count, 3)
        XCTAssertEqual(list.newest.supersedes, [Self.sha1Arm, Self.sha1X86])
    }

    func testRejectsOtherSchemas() {
        XCTAssertNil(decode(Self.json(schema: 2)))
        XCTAssertNil(decode(Self.json(schema: nil)))
        XCTAssertNil(decode(Self.json(newest: "0.9.5-ms.9")))
        XCTAssertNil(decode(Self.json(sha: String(repeating: "A", count: 64))))
        XCTAssertNil(decode(Self.json(sha: "abc")))
        XCTAssertNil(decode(Self.json(secondURL: "https://example.com/herdr")))
        XCTAssertNil(HerdrBuildList.decode(Data("not json".utf8)))
    }

    func testUnknownArchKeysAreIgnored() throws {
        let extra = ",\"riscv64\":{\"url\":\"\(Self.base)/v0.9.5-ms.2/herdr-linux-riscv64\",\"sha256\":\"\(Self.sha2Arm)\"}"
        let list = try XCTUnwrap(decode(Self.json(extraAsset: extra)))
        XCTAssertEqual(list.newest.assets.count, 2)
    }

    func testOutdatedBuildRecognition() throws {
        let list = try XCTUnwrap(decode(Self.json()))
        XCTAssertTrue(list.isOutdatedBuild(sha256: Self.sha1Arm))
        XCTAssertTrue(list.isOutdatedBuild(sha256: Self.patched[0]))
        XCTAssertFalse(list.isOutdatedBuild(sha256: Self.sha2Arm))
        XCTAssertFalse(list.isOutdatedBuild(sha256: String(repeating: "9", count: 64)))
        XCTAssertFalse(list.isOutdatedBuild(sha256: nil))
    }

    func testBuildMatching() throws {
        let list = try XCTUnwrap(decode(Self.json()))
        XCTAssertEqual(list.build(matching: HerdrBuildVersion("0.9.5-ms.1"), sha256: nil)?.version.display, "0.9.5-ms.1")
        XCTAssertEqual(list.build(matching: nil, sha256: Self.sha2X86)?.version.display, "0.9.5-ms.2")
        XCTAssertNil(list.build(matching: HerdrBuildVersion("0.9.5-ms.7"), sha256: String(repeating: "9", count: 64)))
        XCTAssertNil(list.build(matching: nil, sha256: nil))
    }
}
