import AppKit
@testable import FlockCore
import XCTest

@MainActor
final class ProfilePickerContextTests: XCTestCase {
    private let mini = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")

    private final class Switches {
        var ids: [String] = []
    }

    private func store() throws -> ProfileStore {
        let suite = "ProfilePickerContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ProfileStore(
            userDefaults: defaults, bundleID: "dev.acme.flock-tests", defaultSocketPath: "/tmp/acme.sock",
            home: "/Users/acme", removeSuite: { _ in }
        )
    }

    private func context(
        _ store: ProfileStore, isLocked: Bool = false, switches: Switches = Switches(),
        machines: [HerdrMachine]? = nil, keyWindow: NSWindow? = nil
    ) -> ProfilePickerContext {
        ProfilePickerContext(
            profiles: store, isLocked: isLocked,
            switchProfile: { id in
                await MainActor.run { switches.ids.append(id) }
                return true
            },
            listMachines: { machines },
            keyWindow: { keyWindow }
        )
    }

    func testAnUnreadableMachineListChangesNothing() async throws {
        let store = try store()
        store.syncMachines([mini])
        let before = store.profiles
        await context(store, machines: nil).refreshMachines()
        XCTAssertEqual(store.profiles, before)
    }

    func testAMachineListSyncsTheProfiles() async throws {
        let store = try store()
        await context(store, machines: [mini]).refreshMachines()
        XCTAssertEqual(store.profiles.filter(\.isMachine).map(\.name), ["acme-mini"])
    }

    func testChoosingTheCurrentProfileOnlyClosesTheList() async throws {
        let store = try store()
        let switches = Switches()
        let picker = context(store, switches: switches)
        picker.isOpen = true
        picker.choose(FlockProfile.defaultID)
        XCTAssertFalse(picker.isOpen)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(switches.ids, [])
    }

    func testChoosingAnotherProfileClosesTheListAndSwitches() async throws {
        let store = try store()
        store.syncMachines([mini])
        let switches = Switches()
        let picker = context(store, switches: switches)
        picker.isOpen = true
        picker.choose("machine.\(mini.id)")
        XCTAssertFalse(picker.isOpen)
        for _ in 0..<50 where switches.ids.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(switches.ids, ["machine.\(mini.id)"])
    }

    func testTheShortcutOpensOnlyAMountedPickerInTheKeyWindow() throws {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false

        let unmounted = context(try store(), keyWindow: window)
        unmounted.anchorWindow = window
        unmounted.open()
        XCTAssertFalse(unmounted.isOpen, "no picker on screen")
        XCTAssertFalse(unmounted.canOpen)
        XCTAssertFalse(unmounted.canOpenFromShortcut)

        let locked = context(try store(), isLocked: true, keyWindow: window)
        locked.anchorWindow = window
        locked.mount()
        locked.open()
        locked.open(fromClick: true)
        XCTAssertFalse(locked.isOpen, "profiles are off under an override")

        let behindSettings = context(try store(), keyWindow: other)
        behindSettings.anchorWindow = window
        behindSettings.mount()
        behindSettings.open()
        XCTAssertFalse(behindSettings.isOpen, "another window is key")
        XCTAssertFalse(behindSettings.canOpenFromShortcut, "the menu item is disabled while another window is key")
        behindSettings.open(fromClick: true)
        XCTAssertTrue(behindSettings.isOpen, "a click is in the picker's own window")

        let key = context(try store(), keyWindow: window)
        key.anchorWindow = window
        key.mount()
        XCTAssertTrue(key.canOpenFromShortcut)
        key.open()
        XCTAssertTrue(key.isOpen)
        key.unmount()
        XCTAssertFalse(key.isOpen, "the last picker going away closes the list")
    }
}
