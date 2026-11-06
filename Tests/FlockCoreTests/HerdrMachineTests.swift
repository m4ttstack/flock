import XCTest
@testable import FlockCore

final class HerdrMachineTests: XCTestCase {
    func testParseKeepsEnabledMachinesOnly() {
        let json = #"[{"id":"0123456789abcdef0123456789abcdef","label":"acme-mini","target":"acme-mini","session":"default","enabled":true,"selected":false},{"id":"fedcba9876543210fedcba9876543210","label":"off","target":"off","session":"default","enabled":false,"selected":false}]"#
        XCTAssertEqual(
            HerdrMachineList.parse(Data(json.utf8)),
            [HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")]
        )
    }

    func testParseRejectsOtherOutput() {
        XCTAssertNil(HerdrMachineList.parse(Data("nope".utf8)))
    }
}
