import XCTest
@testable import FlockCore

final class HerdrServerAddressTests: XCTestCase {
    private let home = "/Users/someone"
    private let defaultSocket = "/Users/someone/.config/herdr/herdr.sock"
    private let acmeSocket = "/Users/someone/.config/herdr/sessions/acme/herdr.sock"

    func testTheDefaultSocketIsTheDefaultServer() {
        XCTAssertEqual(HerdrServerAddress(socketPath: defaultSocket, home: home), .defaultServer)
    }
    func testASessionsSocketIsNamed() {
        XCTAssertEqual(HerdrServerAddress(socketPath: acmeSocket, home: home), .named("acme"))
    }
    func testAnythingElseIsCustom() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/tmp/acme/x.sock", home: home), .custom("/tmp/acme/x.sock"))
    }
    func testSpellingsOfOneServerResolveAlike() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "~/.config/herdr/herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/./herdr.sock", home: home), .defaultServer)
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/sessions/x/../acme/herdr.sock", home: home), .named("acme"))
        XCTAssertEqual(HerdrServerAddress.normalize("/tmp//acme/x.sock/", home: home), "/tmp/acme/x.sock")
    }
    func testAFullPathIsAbsoluteOrUnderHome() {
        XCTAssertTrue(HerdrServerAddress.isFullPath("/tmp/x.sock"))
        XCTAssertTrue(HerdrServerAddress.isFullPath("~/x.sock"))
        XCTAssertTrue(HerdrServerAddress.isFullPath("~"))
        XCTAssertFalse(HerdrServerAddress.isFullPath("~acme/x.sock"))
        XCTAssertFalse(HerdrServerAddress.isFullPath("x.sock"))
        XCTAssertFalse(HerdrServerAddress.isFullPath(""))
    }
    func testARelativePathKeepsItsLeadingDotDot() {
        XCTAssertEqual(HerdrServerAddress.normalize("../herdr.sock", home: home), "../herdr.sock")
        XCTAssertEqual(HerdrServerAddress.normalize("a/../../x.sock", home: home), "../x.sock")
        XCTAssertEqual(HerdrServerAddress.normalize("/../x.sock", home: home), "/x.sock")
    }
    func testADotDotSessionIsNotNamed() {
        XCTAssertEqual(HerdrServerAddress(socketPath: "/Users/someone/.config/herdr/sessions/../herdr.sock", home: home), .defaultServer)
    }
    func testSocketPathRoundTrips() {
        XCTAssertEqual(HerdrServerAddress.named("acme").socketPath(home: home), acmeSocket)
        XCTAssertEqual(HerdrServerAddress.defaultServer.socketPath(home: home), defaultSocket)
    }
    func testLabels() {
        XCTAssertEqual(HerdrServerAddress.defaultServer.label, "default")
        XCTAssertEqual(HerdrServerAddress.named("acme").label, "acme")
        XCTAssertEqual(HerdrServerAddress.custom("/tmp/acme/x.sock").label, "acme")
    }
    func testOnlyCustomIsNotStartable() {
        XCTAssertTrue(HerdrServerAddress.defaultServer.isStartable)
        XCTAssertTrue(HerdrServerAddress.named("acme").isStartable)
        XCTAssertFalse(HerdrServerAddress.custom("/tmp/x.sock").isStartable)
    }
    func testServerNameValidation() {
        XCTAssertTrue(HerdrServerAddress.isValidSessionName("acme-demo_1.2"))
        for bad in ["", " ", "a b", "a/b", ".", "..", ".hidden", "-x", "default", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrServerAddress.isValidSessionName(bad), bad)
        }
    }
}
