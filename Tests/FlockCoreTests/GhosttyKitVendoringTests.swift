import XCTest
@testable import FlockCore

final class GhosttyKitVendoringTests: XCTestCase {
    func testGhosttyInitEntryPointResolves() {
        let raw = unsafeBitCast(GhosttyKitVendoring.entryPoint, to: UnsafeRawPointer.self)
        XCTAssertNotEqual(UInt(bitPattern: raw), 0)
    }
}
