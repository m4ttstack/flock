import XCTest
@testable import FlockCore

final class HerdrConfigLocationTests: XCTestCase {
    func testDefaultsToHerdrsOwnConfigDirectory() {
        XCTAssertEqual(
            HerdrConfigLocation.path(environment: [:], home: "/Users/example"),
            "/Users/example/.config/herdr/config.toml"
        )
    }

    func testFollowsXdgConfigHome() {
        XCTAssertEqual(
            HerdrConfigLocation.path(environment: ["XDG_CONFIG_HOME": "/cfg"], home: "/Users/example"),
            "/cfg/herdr/config.toml"
        )
    }

    /// The explicit override wins over everything, the way herdr's own
    /// `config_path` reads it.
    func testAnExplicitPathOverridesBoth() {
        XCTAssertEqual(
            HerdrConfigLocation.path(
                environment: ["HERDR_CONFIG_PATH": "/tmp/other.toml", "XDG_CONFIG_HOME": "/cfg"],
                home: "/Users/example"
            ),
            "/tmp/other.toml"
        )
    }

    func testAnEmptyOverrideIsNoOverride() {
        XCTAssertEqual(
            HerdrConfigLocation.path(environment: ["HERDR_CONFIG_PATH": ""], home: "/Users/example"),
            "/Users/example/.config/herdr/config.toml"
        )
    }
}

@MainActor
final class HerdrKeybindingsSourceTests: XCTestCase {
    private final class Disk {
        var stamp: HerdrConfigStamp? = HerdrConfigStamp(modified: Date(timeIntervalSince1970: 0), size: 10)
        var text: String? = """
            [keys]
            prefix = "ctrl+a"
            """
        var stamps = 0
        var reads = 0
    }

    private func source(_ disk: Disk, clock: @escaping () -> Date) -> HerdrKeybindingsSource {
        HerdrKeybindingsSource(
            interval: 1,
            now: clock,
            stamp: { disk.stamps += 1; return disk.stamp },
            contents: { disk.reads += 1; return disk.text }
        )
    }

    func testTheFirstAskReadsTheFile() {
        let disk = Disk()
        let source = source(disk) { Date(timeIntervalSince1970: 0) }
        XCTAssertEqual(source.current().prefix, HerdrKeyCombo(.character("a"), .control))
        XCTAssertEqual(disk.reads, 1)
    }

    func testAsksInsideTheIntervalDoNotTouchTheDisk() {
        let disk = Disk()
        var clock = Date(timeIntervalSince1970: 0)
        let source = source(disk) { clock }
        _ = source.current()
        clock = Date(timeIntervalSince1970: 0.5)
        _ = source.current()
        XCTAssertEqual(disk.stamps, 1)
        XCTAssertEqual(disk.reads, 1)
    }

    func testAnUnchangedFileIsNotReadAgain() {
        let disk = Disk()
        var clock = Date(timeIntervalSince1970: 0)
        let source = source(disk) { clock }
        _ = source.current()
        clock = Date(timeIntervalSince1970: 5)
        _ = source.current()
        XCTAssertEqual(disk.stamps, 2, "the stamp is what says whether to read")
        XCTAssertEqual(disk.reads, 1)
    }

    func testAnEditedFileIsPickedUp() {
        let disk = Disk()
        var clock = Date(timeIntervalSince1970: 0)
        let source = source(disk) { clock }
        _ = source.current()
        disk.stamp = HerdrConfigStamp(modified: Date(timeIntervalSince1970: 60), size: 40)
        disk.text = """
            [keys]
            prefix = "ctrl+x"
            """
        clock = Date(timeIntervalSince1970: 5)
        XCTAssertEqual(source.current().prefix, HerdrKeyCombo(.character("x"), .control))
        XCTAssertEqual(disk.reads, 2)
    }

    /// No config file at all is how herdr runs out of the box, and it means
    /// herdr's own defaults rather than no bindings.
    func testAMissingFileLeavesHerdrsDefaults() {
        let disk = Disk()
        disk.stamp = nil
        disk.text = nil
        let source = source(disk) { Date(timeIntervalSince1970: 0) }
        XCTAssertEqual(source.current().prefix, HerdrKeyCombo(.character("b"), .control))
    }

    /// A config deleted while flock is running goes back to the defaults
    /// rather than keeping the keymap it had.
    func testADeletedFileFallsBackToTheDefaults() {
        let disk = Disk()
        var clock = Date(timeIntervalSince1970: 0)
        let source = source(disk) { clock }
        XCTAssertEqual(source.current().prefix, HerdrKeyCombo(.character("a"), .control))
        disk.stamp = nil
        disk.text = nil
        clock = Date(timeIntervalSince1970: 5)
        XCTAssertEqual(source.current().prefix, HerdrKeyCombo(.character("b"), .control))
    }
}
