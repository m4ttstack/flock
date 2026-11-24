import XCTest

@testable import FlockCore

final class HerdrBuildDecisionTests: XCTestCase {
    private let path = "/home/u/.local/bin/herdr"
    private let list = HerdrBuildList.decode(Data(HerdrBuildListTests.json().utf8))!

    private func decide(
        exists: Bool = true, _ version: String? = nil, sha: String? = nil, list: HerdrBuildList? = nil,
        useList: Bool = true, listPending: Bool = false, writable: Bool = true
    ) -> HerdrBuildState {
        HerdrBuildDecision.decide(
            binaryExists: exists, version: version.flatMap { HerdrBuildVersion($0) }, sha256: sha,
            list: useList ? (list ?? self.list) : nil, listPending: listPending, arch: .arm64, installPath: path,
            isWritable: writable
        )
    }

    func testNoBinaryInWritableLocationIsMissing() {
        XCTAssertEqual(decide(exists: false), .missing(installPath: path))
    }

    func testNoBinaryUnwritableIsNotWritable() {
        XCTAssertEqual(decide(exists: false, writable: false), .notWritable(installPath: path))
    }

    func testNoListIsUnavailable() {
        XCTAssertEqual(decide("0.9.5", useList: false), .listUnavailable(installed: "0.9.5"))
    }

    func testNoListYetIsChecking() {
        XCTAssertEqual(decide("0.9.5", useList: false, listPending: true), .checking(installed: "0.9.5"))
        XCTAssertEqual(decide(nil, useList: false, listPending: true), .checking(installed: nil))
    }

    func testAMissingHerdrIsMissingBeforeTheListIsRead() {
        XCTAssertEqual(decide(exists: false, useList: false, listPending: true), .missing(installPath: path))
        XCTAssertEqual(
            decide(exists: false, useList: false, listPending: true, writable: false), .notWritable(installPath: path))
    }

    func testAListInHandDecidesWhateverIsPending() {
        XCTAssertEqual(decide("0.9.5-ms.2", listPending: true), .current(version: "0.9.5-ms.2"))
    }

    func testListWithoutThisArchIsUnavailable() {
        let build = HerdrBuildList.Build(
            version: HerdrBuildVersion("0.9.5-ms.2")!, changesServer: true,
            assets: [.x86_64: .init(url: HerdrBuildList.url, sha256: HerdrBuildListTests.sha2X86)], supersedes: []
        )
        let noArm = HerdrBuildList(newest: build, builds: [build], flockPatchSha256: [])
        XCTAssertEqual(decide("0.9.5", list: noArm), .listUnavailable(installed: "0.9.5"))
        XCTAssertEqual(decide("0.9.5", list: noArm, listPending: true), .listUnavailable(installed: "0.9.5"))
    }

    func testNewestShaIsCurrent() {
        XCTAssertEqual(decide(nil, sha: HerdrBuildListTests.sha2Arm), .current(version: "0.9.5-ms.2"))
    }

    func testNewestVersionStringIsCurrentEvenWithOtherBytes() {
        XCTAssertEqual(decide("0.9.5-ms.2", sha: String(repeating: "9", count: 64)), .current(version: "0.9.5-ms.2"))
    }

    func testNewerForkBuildThanListIsCurrent() {
        XCTAssertEqual(decide("0.9.6-ms.1"), .current(version: "0.9.6-ms.1"))
    }

    func testOlderForkBuildIsOutdated() {
        XCTAssertEqual(
            decide("0.9.5-ms.1", sha: String(repeating: "9", count: 64)),
            .outdated(installPath: path, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2"))
    }

    func testFlockPatchedShaIsOutdated() {
        XCTAssertEqual(
            decide("0.9.5", sha: HerdrBuildListTests.patched[1]),
            .outdated(installPath: path, installed: "0.9.5", newest: "0.9.5-ms.2"))
    }

    func testSupersededShaIsOutdated() {
        XCTAssertEqual(
            decide("0.9.5", sha: HerdrBuildListTests.sha1X86),
            .outdated(installPath: path, installed: "0.9.5", newest: "0.9.5-ms.2"))
    }

    func testStockIsStock() {
        let other = String(repeating: "9", count: 64)
        XCTAssertEqual(decide("0.9.5", sha: other), .stock(installPath: path, installed: "0.9.5", newest: "0.9.5-ms.2"))
        XCTAssertEqual(decide("0.9.6", sha: other), .stock(installPath: path, installed: "0.9.6", newest: "0.9.5-ms.2"))
        XCTAssertEqual(decide(nil, sha: other), .stock(installPath: path, installed: nil, newest: "0.9.5-ms.2"))
    }

    func testReplaceableButUnwritableIsNotWritable() {
        XCTAssertEqual(decide("0.9.5", writable: false), .notWritable(installPath: path))
        XCTAssertEqual(decide("0.9.5-ms.1", writable: false), .notWritable(installPath: path))
    }
}
