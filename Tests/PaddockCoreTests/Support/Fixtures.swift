import XCTest

extension XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle(for: Self.self).url(forResource: name, withExtension: nil)!)
    }

    func fixtureLines(_ name: String) throws -> [Data] {
        try (fixture(name).split(separator: 0x0A) as [Data])
    }
}
