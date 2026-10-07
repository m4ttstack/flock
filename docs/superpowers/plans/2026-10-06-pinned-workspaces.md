# Pinned Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a pinned workspace stays in the rail's PINNED section with its name, symbol and order after every tab in it closes, and clicking it reopens a fresh shell in its home folder.

**Architecture:** flock owns the pins. `PinnedWorkspaceStore` (FlockCore, persisted) holds them and links each to the live herdr workspace by id, re-linking on every model update by the rules in the spec. `SessionViewModel` owns the store, reconciles it in `update(model:connection:)`, and does pinning, reopening and the close-prompt change. `RailSections` carries the pins so every view that orders workspaces (rail, Arrange, Overview, shortcuts) puts PINNED first. The drag system gains a PINNED drop target and a `.pin` subject for empty pins.

**Tech Stack:** Swift 6, SwiftUI/AppKit (macOS), XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-06-pinned-workspaces-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host, ticket id or private workspace link anywhere, in code, fixtures, docs or commit messages. Fixtures use `acme`.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them). Use "..." or the `\u{2026}` character in UI strings.
- Comments state constraints the code cannot show; no narration, no decision history.
- Tests stay hermetic: no test may spawn rt, herdr, herdr-chat or deck, read `~/.mattstack`, or reach the network.
- Never quit, kill or launch any app named Flock. Do not run `Scripts/dev-build.sh`; the controller does.
- Build and test with a scratch derived data path: `-derivedDataPath build/dd -skipPackagePluginValidation`. Run only the test classes a task names, never whole suites.
- Run `xcodegen` after adding or removing files. Run `Scripts/checks.sh` after `git add`.
- The worktree guard rejects complex shell lines involving git (pipes, shell variables, chained cd). Use plain separate commands with `git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy ...`.
- Every commit message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- UI changes are rendered in a dark and a light theme and looked at before committing.
- Exact strings: section heading `PINNED`; menu rows `Rename`, `Change Symbol…`, `Change Folder…`, `Pin`, `Unpin`, `Remove`, `Close`; identity key prefix `pin:`; defaults key `flock.pinnedWorkspaces`.

## Review Focus

1. A reopen whose create succeeds but whose first snapshot does not yet carry the new workspace: the pin must stay linked, not unlink as "gone". Test in Task 1 (`testALinkFromACreateSurvivesSnapshotsThatDoNotCarryItYet`).
2. A stale snapshot after a reopen still showing herdr's default label: the pin's name must not change to it. Test in Task 1 (`testAFreshLinkTakesTheFirstLabelItSeesWithoutRenaming`).
3. A herd or flock-owned workspace whose label matches an empty pin: never adopted. Test in Task 1 (`testAdoptionSkipsWorkspacesThatAreNotRailRows`).
4. Dragging a WORKSPACES row while pinned workspaces sit between rows in herdr's order: the herdr move index skips the pinned ones. Test in Task 2 (`testModelInsertIndexSkipsPinnedWorkspaces`).
5. Two clicks on an empty pin before the first create returns: exactly one `workspace.create`. Test in Task 5 (`testASecondReopenWhileOneIsInFlightSendsNothing`).

---

### Task 1: The pin record, its store and the linking rules

**Files:**
- Create: `Sources/FlockCore/Rail/PinnedWorkspaces.swift`
- Test: `Tests/FlockCoreTests/PinnedWorkspaceStoreTests.swift`

**Interfaces:**
- Consumes: `SessionModel`, `WorkspaceRecord`, `WorkspaceID` (existing).
- Produces:
  - `public struct PinID: RawRepresentable, Hashable, Codable, Sendable` with `static func make() -> PinID`.
  - `public struct PinnedWorkspace: Equatable, Codable, Sendable, Identifiable` with `id: PinID`, `name: String`, `folder: String`, `workspace: WorkspaceID?`, `syncedLabel: String?`, `confirmed: Bool`, `identityKey: String` (`"pin:" + id.rawValue`).
  - `public enum PinNames { static func matches(_:_:) -> Bool }`.
  - `@MainActor @Observable public final class PinnedWorkspaceStore` with `init(userDefaults: UserDefaults?)`, `pins: [PinnedWorkspace]`, `pin(_ id: PinID) -> PinnedWorkspace?`, `pin(linkedTo: WorkspaceID) -> PinnedWorkspace?`, `isNameTaken(_ name: String, except: PinID?) -> Bool`, `add(workspace:name:folder:at:) -> PinnedWorkspace?`, `remove(_:)`, `move(_:toInsertIndex:)`, `rename(_:to:) -> Bool`, `setFolder(_:to:)`, `link(_:to:)`, `reconcile(with:eligible:)`.
  - `public enum PinFolders { static func firstPane(of: WorkspaceID, in: SessionModel) -> String? }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class PinnedWorkspaceStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "flock-pins-\(UUID().uuidString)")!
    }

    private func model(_ workspaces: [(id: String, label: String)]) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: workspaces.enumerated().map { index, item in
                WorkspaceRecord(
                    workspaceID: WorkspaceID(rawValue: item.id), label: item.label, number: index + 1,
                    activeTabID: TabID(rawValue: "\(item.id):t1"), agentStatus: .idle
                )
            },
            tabs: workspaces.map {
                TabRecord(tabID: TabID(rawValue: "\($0.id):t1"), workspaceID: WorkspaceID(rawValue: $0.id),
                          label: "zsh", number: 1, paneCount: 1, agentStatus: .idle)
            },
            panes: workspaces.map {
                PaneRecord(paneID: PaneID(rawValue: "\($0.id):p1"), workspaceID: WorkspaceID(rawValue: $0.id),
                           tabID: TabID(rawValue: "\($0.id):t1"), focused: false, agentStatus: .idle, revision: 0,
                           terminalTitleStripped: nil, label: nil, cwd: "/acme/\($0.label)", scroll: nil)
            },
            layouts: []
        ))
    }

    private let anyRow: (WorkspaceRecord) -> Bool = { _ in true }

    func testAddingRefusesATakenNameIgnoringCaseAndSpaces() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        XCTAssertNotNil(store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil))
        XCTAssertNil(store.add(workspace: WorkspaceID(rawValue: "w2"), name: " ACME ", folder: "/acme", at: nil))
        XCTAssertNil(store.add(workspace: WorkspaceID(rawValue: "w1"), name: "other", folder: "/acme", at: nil),
                     "a workspace is pinned once")
        XCTAssertEqual(store.pins.map(\.name), ["acme"])
    }

    func testAddInsertsAtTheGivenIndexAndMoveReorders() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "b", folder: "/b", at: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "c", folder: "/c", at: 0)
        XCTAssertEqual(store.pins.map(\.name), ["c", "a", "b"])
        store.move(a.id, toInsertIndex: 3)
        XCTAssertEqual(store.pins.map(\.name), ["c", "b", "a"])
        store.move(a.id, toInsertIndex: 0)
        XCTAssertEqual(store.pins.map(\.name), ["a", "c", "b"])
    }

    func testPinsRoundTripThroughDefaultsAndUnreadableDataLoadsEmpty() {
        let defaults = defaults()
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins, store.pins)
        defaults.set(Data("not json".utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins, [])
    }

    func testAPinWhoseWorkspaceIsGoneBecomesEmpty() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([("w2", "other")]), eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace)
        XCTAssertEqual(store.pins[0].name, "acme")
    }

    func testANameFollowsARenameMadeAnywhere() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([("w1", "acme web")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme web")
    }

    func testAnEmptyPinAdoptsTheFirstUnlinkedWorkspaceWithItsNameIgnoringCase() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([]), eligible: anyRow)
        store.reconcile(with: model([("w7", "other"), ("w8", "Acme "), ("w9", "acme")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w8"))
    }

    func testAdoptionSkipsWorkspacesThatAreNotRailRows() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)
        store.reconcile(with: model([]), eligible: anyRow)
        store.reconcile(with: model([("w8", "acme")]), eligible: { $0.workspaceID.rawValue != "w8" })
        XCTAssertNil(store.pins[0].workspace)
    }

    func testALinkFromACreateSurvivesSnapshotsThatDoNotCarryItYet() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let pin = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)
        store.link(pin.id, to: WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].workspace, WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([("w9", "acme")]), eligible: anyRow)
        store.reconcile(with: model([]), eligible: anyRow)
        XCTAssertNil(store.pins[0].workspace, "once herdr has shown it, its absence unlinks")
    }

    func testAFreshLinkTakesTheFirstLabelItSeesWithoutRenaming() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let pin = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "acme", folder: "/acme", at: nil)!
        store.reconcile(with: model([]), eligible: anyRow)
        store.link(pin.id, to: WorkspaceID(rawValue: "w9"))
        store.reconcile(with: model([("w9", "3")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme")
        store.reconcile(with: model([("w9", "acme")]), eligible: anyRow)
        XCTAssertEqual(store.pins[0].name, "acme")
    }

    func testRenameRefusesAnotherPinsName() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "b", folder: "/b", at: nil)
        XCTAssertFalse(store.rename(a.id, to: "B"))
        XCTAssertTrue(store.rename(a.id, to: "c"))
        XCTAssertEqual(store.pins.map(\.name), ["c", "b"])
    }

    func testTheFirstPaneFolderIsItsForegroundFolderElseItsCwd() {
        var model = model([("w1", "acme")])
        XCTAssertEqual(PinFolders.firstPane(of: WorkspaceID(rawValue: "w1"), in: model), "/acme/acme")
        model.panes[PaneID(rawValue: "w1:p1")]?.foregroundCwd = "/acme/apps/web"
        XCTAssertEqual(PinFolders.firstPane(of: WorkspaceID(rawValue: "w1"), in: model), "/acme/apps/web")
        XCTAssertNil(PinFolders.firstPane(of: WorkspaceID(rawValue: "nope"), in: model))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen` then `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/PinnedWorkspaceStoreTests`
Expected: build failure, `cannot find 'PinnedWorkspaceStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Observation

public struct PinID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func make() -> PinID { PinID(rawValue: UUID().uuidString) }
}

/// A place the person keeps: it outlives the herdr workspace it is linked to.
public struct PinnedWorkspace: Equatable, Codable, Sendable, Identifiable {
    public let id: PinID
    public var name: String
    public var folder: String
    /// nil while nothing is open for the pin.
    public var workspace: WorkspaceID?
    /// herdr's label for `workspace` when last reconciled. nil right after a
    /// link from a create, so the first label seen is taken without renaming
    /// the pin: it is herdr's default until the rename lands.
    public var syncedLabel: String?
    /// Whether herdr has reported `workspace` since it was linked. A create's
    /// reply links before any snapshot carries the workspace, and that gap is
    /// not the workspace closing.
    public var confirmed: Bool

    public var identityKey: String { "pin:\(id.rawValue)" }
}

public enum PinNames {
    public static func matches(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum PinFolders {
    /// The folder of the first pane of the workspace's first tab, as it is:
    /// never widened to its repo, since one repo can hold many places.
    public static func firstPane(of workspace: WorkspaceID, in model: SessionModel) -> String? {
        guard let tab = model.tabs[workspace]?.first else { return nil }
        let inLayout = (model.layouts[tab.tabID]?.panes ?? []).lazy.compactMap { model.panes[$0.paneID] }.first
        let pane = inLayout ?? model.panes.values
            .filter { $0.tabID == tab.tabID }
            .min { $0.paneID.rawValue < $1.paneID.rawValue }
        return pane.map { $0.foregroundCwd ?? $0.cwd }
    }
}

@MainActor
@Observable
public final class PinnedWorkspaceStore {
    public static let defaultsKey = "flock.pinnedWorkspaces"

    public private(set) var pins: [PinnedWorkspace]

    @ObservationIgnored private let userDefaults: UserDefaults?

    private struct Stored: Codable {
        var version: Int
        var pins: [PinnedWorkspace]
    }

    /// nil keeps the pins in memory only.
    public init(userDefaults: UserDefaults?) {
        self.userDefaults = userDefaults
        pins = userDefaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            .map(\.pins) ?? []
    }

    public func pin(_ id: PinID) -> PinnedWorkspace? {
        pins.first { $0.id == id }
    }

    public func pin(linkedTo workspace: WorkspaceID) -> PinnedWorkspace? {
        pins.first { $0.workspace == workspace }
    }

    public func isNameTaken(_ name: String, except: PinID?) -> Bool {
        pins.contains { $0.id != except && PinNames.matches($0.name, name) }
    }

    @discardableResult
    public func add(workspace: WorkspaceID, name: String, folder: String, at index: Int?) -> PinnedWorkspace? {
        guard pin(linkedTo: workspace) == nil, !isNameTaken(name, except: nil) else { return nil }
        let pin = PinnedWorkspace(
            id: .make(), name: name, folder: folder, workspace: workspace, syncedLabel: name, confirmed: true
        )
        pins.insert(pin, at: min(max(index ?? pins.count, 0), pins.count))
        save()
        return pin
    }

    public func remove(_ id: PinID) {
        pins.removeAll { $0.id == id }
        save()
    }

    /// `index` counts the pins as drawn, the moving one included.
    public func move(_ id: PinID, toInsertIndex index: Int) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        var next = pins
        let moving = next.remove(at: from)
        let target = index > from ? index - 1 : index
        next.insert(moving, at: min(max(target, 0), next.count))
        guard next != pins else { return }
        pins = next
        save()
    }

    public func rename(_ id: PinID, to name: String) -> Bool {
        guard let index = pins.firstIndex(where: { $0.id == id }), !isNameTaken(name, except: id) else { return false }
        pins[index].name = name
        save()
        return true
    }

    public func setFolder(_ id: PinID, to folder: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].folder = folder
        save()
    }

    /// Links from a create's reply, before any snapshot carries the workspace.
    public func link(_ id: PinID, to workspace: WorkspaceID) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].workspace = workspace
        pins[index].syncedLabel = nil
        pins[index].confirmed = false
        save()
    }

    /// Keeps links that herdr still reports (names following its renames),
    /// empties pins whose workspace herdr has shown and no longer does, then
    /// lets each empty pin adopt the first unlinked `eligible` workspace with
    /// its name.
    public func reconcile(with model: SessionModel, eligible: (WorkspaceRecord) -> Bool) {
        var next = pins
        var records: [WorkspaceID: WorkspaceRecord] = [:]
        for record in model.workspaces where records[record.workspaceID] == nil { records[record.workspaceID] = record }
        for index in next.indices {
            guard let workspace = next[index].workspace else { continue }
            if let record = records[workspace] {
                next[index].confirmed = true
                if let synced = next[index].syncedLabel, synced != record.label { next[index].name = record.label }
                next[index].syncedLabel = record.label
            } else if next[index].confirmed {
                next[index].workspace = nil
                next[index].syncedLabel = nil
                next[index].confirmed = false
            }
        }
        var linked = Set(next.compactMap(\.workspace))
        for index in next.indices where next[index].workspace == nil {
            guard let record = model.workspaces.first(where: {
                !linked.contains($0.workspaceID) && eligible($0) && PinNames.matches($0.label, next[index].name)
            }) else { continue }
            next[index].workspace = record.workspaceID
            next[index].syncedLabel = record.label
            next[index].confirmed = true
            linked.insert(record.workspaceID)
        }
        guard next != pins else { return }
        pins = next
        save()
    }

    private func save() {
        guard let userDefaults else { return }
        let data = try? JSONEncoder().encode(Stored(version: 1, pins: pins))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/PinnedWorkspaceStoreTests`
Expected: `** TEST SUCCEEDED **`, 11 tests.

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add Sources/FlockCore/Rail/PinnedWorkspaces.swift Tests/FlockCoreTests/PinnedWorkspaceStoreTests.swift Flock.xcodeproj
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: a pinned workspace record, its store and the rules that link it to herdr" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Rail sections and symbol keys know the pins

**Files:**
- Modify: `Sources/FlockCore/Rail/RailSections.swift` (whole struct, lines 9-80)
- Modify: `Sources/FlockCore/Theme/WorkspaceIdentityStore.swift` (`key(for:sections:)` line 30, `keys(in:)` line 45, add `rekey`)
- Modify: `Sources/FlockCore/Mutations/GesturePlanner.swift:37-43` and the function that calls it, to thread `pinned`
- Test: `Tests/FlockCoreTests/RailSectionsTests.swift`, `Tests/FlockCoreTests/WorkspaceIdentityStoreTests.swift`

**Interfaces:**
- Consumes: `PinnedWorkspace`, `PinID` (Task 1).
- Produces:
  - `RailSections.init(model:board:herdProgress:pins: [PinnedWorkspace] = [])`.
  - `public struct RailSections.PinnedRow: Equatable, Sendable { pin: PinnedWorkspace; record: WorkspaceRecord? }` and `RailSections.pinned: [PinnedRow]`.
  - `railOrder` and `navigationOrder` lead with linked pins.
  - `RailSections.modelInsertIndex(forRailIndex:in:board:pinned: Set<WorkspaceID> = [])`.
  - `WorkspaceIdentityStore.key(for:sections:)` returns a pin's `identityKey` for a linked pin; `keys(in:)` starts with every pin's key; `func rekey(from: String, to: String)`.

- [ ] **Step 1: Write the failing tests**

Add to `RailSectionsTests` (reuse the file's existing model builder if it has one; otherwise copy the `model(_:)` builder from Task 1's test file into this file as a `private` helper):

```swift
func testLinkedPinsLeaveWorkspacesAndLeadTheRailOrder() {
    let model = model([("w1", "acme"), ("w2", "notes"), ("w3", "web")])
    let pins = [
        PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w3"), syncedLabel: "web", confirmed: true),
        PinnedWorkspace(id: PinID(rawValue: "p2"), name: "gone", folder: "/gone", workspace: nil, syncedLabel: nil, confirmed: false),
    ]
    let sections = RailSections(model: model, board: nil, pins: pins)
    XCTAssertEqual(sections.workspaces.map(\.label), ["acme", "notes"])
    XCTAssertEqual(sections.pinned.map(\.pin.name), ["web", "gone"])
    XCTAssertEqual(sections.pinned.map { $0.record?.label }, ["web", nil])
    XCTAssertEqual(sections.railOrder.map(\.rawValue), ["w3", "w1", "w2"])
    XCTAssertEqual(sections.navigationOrder { _ in false }.map(\.title), ["web", "acme", "notes"])
}

func testModelInsertIndexSkipsPinnedWorkspaces() {
    let model = model([("w1", "acme"), ("w2", "web"), ("w3", "notes")])
    let pinned: Set<WorkspaceID> = [WorkspaceID(rawValue: "w2")]
    XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 1, in: model, board: nil, pinned: pinned), 2)
    XCTAssertEqual(RailSections.modelInsertIndex(forRailIndex: 2, in: model, board: nil, pinned: pinned), 3)
}
```

Add to `WorkspaceIdentityStoreTests`:

```swift
func testALinkedPinIsKeyedByThePinAndEveryPinKeyIsKept() {
    let model = model([("w1", "acme"), ("w2", "web")])
    let pins = [
        PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "web", confirmed: true),
        PinnedWorkspace(id: PinID(rawValue: "p2"), name: "gone", folder: "/gone", workspace: nil, syncedLabel: nil, confirmed: false),
    ]
    let sections = RailSections(model: model, board: nil, pins: pins)
    XCTAssertEqual(WorkspaceIdentityStore.key(for: WorkspaceID(rawValue: "w2"), sections: sections), "pin:p1")
    XCTAssertEqual(WorkspaceIdentityStore.keys(in: sections), ["pin:p1", "pin:p2", "w1"])
}

func testRekeyMovesTheAssignmentAndTheOverride() {
    let store = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: "flock-rekey-\(UUID().uuidString)")!)
    store.assign(["w1"])
    store.setOverride("bird.fill", for: "w1")
    store.rekey(from: "w1", to: "pin:p1")
    XCTAssertEqual(store.symbol(for: "pin:p1"), "bird.fill")
    XCTAssertNil(store.symbol(for: "w1"))
}
```

(The identity test file needs the same `model(_:)` builder; copy it in as a `private` helper.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/RailSectionsTests -only-testing:FlockCoreTests/WorkspaceIdentityStoreTests`
Expected: build failure, `extra argument 'pins' in call`.

- [ ] **Step 3: Implement**

In `RailSections`:

```swift
public struct PinnedRow: Equatable, Sendable {
    public let pin: PinnedWorkspace
    /// The linked workspace, nil for an empty pin.
    public let record: WorkspaceRecord?
}

public let pinned: [PinnedRow]

public init(model: SessionModel, board names: BoardWorkspaceNames?, herdProgress: [String: HerdProgress] = [:], pins: [PinnedWorkspace] = []) {
    let herdRail = HerdRail(model: model, progress: herdProgress)
    let labels = names?.labels ?? []
    var records: [WorkspaceID: WorkspaceRecord] = [:]
    for record in model.workspaces where records[record.workspaceID] == nil { records[record.workspaceID] = record }
    pinned = pins.map { PinnedRow(pin: $0, record: $0.workspace.flatMap { records[$0] }) }
    let linked = Set(pinned.compactMap { $0.record?.workspaceID })
    workspaces = herdRail.workspaces.filter { !labels.contains($0.label) && !linked.contains($0.workspaceID) }
    board = labels.flatMap { label in herdRail.workspaces.filter { $0.label == label && !linked.contains($0.workspaceID) } }
    herds = herdRail.herds
    herdSummary = herdRail.summary
}

public var railOrder: [WorkspaceID] {
    pinned.compactMap { $0.record?.workspaceID }
        + workspaces.map(\.workspaceID) + board.map(\.workspaceID) + herds.map(\.workspaceID)
}
```

In `navigationOrder`, start `rows` with the linked pins:

```swift
var rows = pinned.compactMap { row in row.record.map { Row(workspaceID: $0.workspaceID, title: row.pin.name) } }
rows += workspaces.map { Row(workspaceID: $0.workspaceID, title: $0.label) }
```

`modelInsertIndex` gains `pinned: Set<WorkspaceID> = []` and filters it out:

```swift
public static func modelInsertIndex(forRailIndex railIndex: Int, in model: SessionModel, board: BoardWorkspaceNames?, pinned: Set<WorkspaceID> = []) -> Int {
    let railIndices = model.workspaces.indices.filter {
        isRailRow(label: model.workspaces[$0].label, board: board) && !pinned.contains(model.workspaces[$0].workspaceID)
    }
    if railIndex < railIndices.count {
        return railIndices[max(railIndex, 0)]
    }
    return (railIndices.last.map { $0 + 1 }) ?? railIndex
}
```

Add the doc line above `modelInsertIndex`: `/// Pinned workspaces sit in PINNED, outside the rows this index counts.`

In `GesturePlanner.swift`, the `(.workspace, .workspaceRail)` and `(.workspaces, .workspaceRail)` cases pass `pinned:` to `modelInsertIndex`. Thread a `pinned: Set<WorkspaceID> = []` parameter from the planner's public entry point (the function `SessionViewModel.perform` calls, which already takes `board`) down to those cases, with the default so existing callers compile.

In `WorkspaceIdentityStore`:

```swift
public static func key(for workspace: WorkspaceID, sections: RailSections) -> String? {
    if let row = sections.pinned.first(where: { $0.record?.workspaceID == workspace }) { return row.pin.identityKey }
    if sections.herds.contains(where: { $0.workspaceID == workspace }) { return nil }
    if sections.board.contains(where: { $0.workspaceID == workspace }) { return boardKey }
    return workspace.rawValue
}

/// Every pin first, empty ones included, so a closed place keeps its
/// symbol; then every other key the rail shows, in rail order.
public static func keys(in sections: RailSections) -> [String] {
    var seen = Set<String>()
    let pins = sections.pinned.map(\.pin.identityKey)
    let rest = sections.railOrder.compactMap { key(for: $0, sections: sections) }
    return (pins + rest).filter { seen.insert($0).inserted }
}

/// Carries a symbol across a pin or unpin.
public func rekey(from old: String, to new: String) {
    guard old != new else { return }
    if let name = assigned.removeValue(forKey: old) { assigned[new] = name }
    if let name = overrides.removeValue(forKey: old) { overrides[new] = name }
    save()
}
```

`assigned` and `overrides` are `public private(set) var`, so the store can mutate them; `save()` is the existing private method.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/RailSectionsTests -only-testing:FlockCoreTests/WorkspaceIdentityStoreTests -only-testing:FlockCoreTests/GesturePlannerTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -u
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: rail sections lead with pinned workspaces and symbols follow the pin" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The view model owns the pins

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (init 162-183 and body 185-210, `update` 233-273, new pin methods near `closeWorkspace` ~1481)
- Modify: `Sources/Flock/FlockApp.swift` (identity store creation ~149, `SessionViewModel(...)` ~205-220)
- Modify every `RailSections(model:` call site to go through the new helper: `Sources/Flock/FlockApp.swift:479`, `Sources/Flock/Views/WorkspaceRail.swift:23`, `Sources/Flock/Views/AllWorkspacesGrid.swift:144` and `:161`, `Sources/Flock/Views/MissionControl/MissionControlView.swift:357` and `:373`
- Test: `Tests/FlockCoreTests/SessionViewModelPinTests.swift` (create)

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces on `SessionViewModel`:
  - init params `pinnedWorkspaceDefaults: UserDefaults? = nil`, `identity: WorkspaceIdentityStore? = nil` (append after `repoBranches`).
  - `public let pins: PinnedWorkspaceStore`
  - `public func railSections(board: BoardWorkspaceNames?, herdProgress: [String: HerdProgress] = [:]) -> RailSections?`
  - `public func pin(workspace: WorkspaceID, at index: Int? = nil)`
  - `public func unpin(_ id: PinID)`
  - `public func removePin(_ id: PinID)`
  - `public func movePin(_ id: PinID, toInsertIndex index: Int)`
  - `public func setPinFolder(_ id: PinID, to folder: String)`
  - `public func renamePin(_ id: PinID, to text: String)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

private actor QuietClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

@MainActor
final class SessionViewModelPinTests: XCTestCase {
    private func model(_ workspaces: [(id: String, label: String)]) -> SessionModel {
        // Same builder as PinnedWorkspaceStoreTests.model(_:); copy it here verbatim as a private helper.
        fatalError("copy the builder")
    }

    private func viewModel(notices: @escaping @MainActor (String) -> Void = { _ in }) -> (SessionViewModel, WorkspaceIdentityStore) {
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: "flock-pin-vm-\(UUID().uuidString)")!)
        let viewModel = SessionViewModel(client: QuietClient(), noticeSink: notices, identity: identity)
        return (viewModel, identity)
    }

    func testPinningTakesTheNameTheFirstPaneFolderAndTheSymbol() {
        let (viewModel, identity) = viewModel()
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        identity.assign(["w2"])
        let symbol = identity.symbol(for: "w2")
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        let pin = viewModel.pins.pins[0]
        XCTAssertEqual(pin.name, "web")
        XCTAssertEqual(pin.folder, "/acme/web")
        XCTAssertEqual(identity.symbol(for: pin.identityKey), symbol)
        XCTAssertEqual(viewModel.railSections(board: nil)?.workspaces.map(\.label), ["acme"])
    }

    func testUnpinningGivesTheSymbolBackToTheWorkspace() {
        let (viewModel, identity) = viewModel()
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        identity.setOverride("bird.fill", for: "w1")
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.unpin(viewModel.pins.pins[0].id)
        XCTAssertEqual(viewModel.pins.pins, [])
        XCTAssertEqual(identity.symbol(for: "w1"), "bird.fill")
    }

    func testAWorkspaceClosingLeavesAnEmptyPinThatOnlyRemoveDeletes() {
        let (viewModel, _) = viewModel()
        viewModel.update(model: model([("w1", "acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.update(model: model([]), connection: .live)
        let pin = viewModel.pins.pins[0]
        XCTAssertNil(pin.workspace)
        viewModel.unpin(pin.id)
        XCTAssertEqual(viewModel.pins.pins.count, 1, "unpin needs a linked workspace")
        viewModel.removePin(pin.id)
        XCTAssertEqual(viewModel.pins.pins, [])
    }

    func testPinningASecondWorkspaceWithAPinnedNameIsRefusedWithANotice() {
        var notices: [String] = []
        let (viewModel, _) = viewModel(notices: { notices.append($0) })
        viewModel.update(model: model([("w1", "acme"), ("w2", "Acme")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(viewModel.pins.pins.count, 1)
        XCTAssertEqual(notices, ["A pinned workspace is already called \"Acme\"."])
    }

    func testRenamingAnEmptyPinIsLocalAndRefusesATakenName() {
        var notices: [String] = []
        let (viewModel, _) = viewModel(notices: { notices.append($0) })
        viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
        viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
        viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
        viewModel.update(model: model([("w2", "web")]), connection: .live)
        let empty = viewModel.pins.pins[0]
        viewModel.renamePin(empty.id, to: "web")
        viewModel.renamePin(empty.id, to: "  ")
        viewModel.renamePin(empty.id, to: "acme api")
        XCTAssertEqual(viewModel.pins.pin(empty.id)?.name, "acme api")
        XCTAssertEqual(notices, ["A pinned workspace is already called \"web\"."])
    }
}
```

Replace the `fatalError` body with the Task 1 builder before running.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen` then `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelPinTests`
Expected: build failure, `extra argument 'identity' in call`.

- [ ] **Step 3: Implement**

Init: append `pinnedWorkspaceDefaults: UserDefaults? = nil, identity: WorkspaceIdentityStore? = nil` after `repoBranches`. Store `@ObservationIgnored private let identity: WorkspaceIdentityStore?`. In the body, beside `self.completedTabs = TabCompletionStore(userDefaults: completedTabDefaults)`:

```swift
self.pins = PinnedWorkspaceStore(userDefaults: pinnedWorkspaceDefaults)
self.identity = identity
```

Declare beside `completedTabs`:

```swift
/// The workspaces kept as places; they outlive herdr's.
public let pins: PinnedWorkspaceStore
```

In `update(model:connection:)`, inside the `.live` block with `rightClicks.keepOnly`:

```swift
if let model {
    pins.reconcile(with: model) { RailSections.isRailRow(label: $0.label, board: nil) }
}
```

Board names are not known here, so adoption checks herds and flock-owned workspaces only; pinning itself is offered only on rail rows.

New methods, placed after `closeWorkspace`:

```swift
public func railSections(board: BoardWorkspaceNames?, herdProgress: [String: HerdProgress] = [:]) -> RailSections? {
    model.map { RailSections(model: $0, board: board, herdProgress: herdProgress, pins: pins.pins) }
}

public func pin(workspace: WorkspaceID, at index: Int? = nil) {
    guard pins.pin(linkedTo: workspace) == nil, let model,
          let record = model.workspaces.first(where: { $0.workspaceID == workspace }) else { return }
    guard !pins.isNameTaken(record.label, except: nil) else {
        noticeSink("A pinned workspace is already called \"\(record.label)\".")
        return
    }
    let folder = PinFolders.firstPane(of: workspace, in: model) ?? homeDirectory
    guard let pin = pins.add(workspace: workspace, name: record.label, folder: folder, at: index) else { return }
    identity?.rekey(from: workspace.rawValue, to: pin.identityKey)
}

public func unpin(_ id: PinID) {
    guard let pin = pins.pin(id), let workspace = pin.workspace else { return }
    pins.remove(id)
    identity?.rekey(from: pin.identityKey, to: workspace.rawValue)
}

public func removePin(_ id: PinID) {
    guard pins.pin(id)?.workspace == nil else { return }
    pins.remove(id)
}

public func movePin(_ id: PinID, toInsertIndex index: Int) {
    pins.move(id, toInsertIndex: index)
}

public func setPinFolder(_ id: PinID, to folder: String) {
    pins.setFolder(id, to: folder)
}

/// An empty pin's rename: nothing in herdr carries its name.
public func renamePin(_ id: PinID, to text: String) {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, pins.pin(id)?.workspace == nil else { return }
    guard pins.rename(id, to: name) else {
        noticeSink("A pinned workspace is already called \"\(name)\".")
        return
    }
}
```

`homeDirectory` is the existing stored init parameter. Check its property name in the init body and use that name.

Call sites: replace each `RailSections(model: X, board: B, herdProgress: H)` with `viewModel.railSections(board: B, herdProgress: H)` (it returns an optional; where the code already maps over `viewModel.model`, map over the helper instead). In `WorkspaceRail.swift:23`: `viewModel.railSections(board: board.names, herdProgress: herdProgress.progress)`. In `MissionControlView` 357/373 and `AllWorkspacesGrid` 144/161, use the view's `viewModel`; where a function receives `model` as a parameter, add a `pins: [PinnedWorkspace]` parameter fed from `viewModel.pins.pins` and pass it to `RailSections(... pins:)`.

`FlockApp.swift`: create the identity store once and hand it to both. Where `_workspaceIdentityStore = State(initialValue: WorkspaceIdentityStore())` is (~149), introduce `let identity = WorkspaceIdentityStore()` before the view model is built, use `State(initialValue: identity)`, and pass `pinnedWorkspaceDefaults: .standard, identity: identity` to `SessionViewModel(...)`. If the view model is built before line 149, move the identity creation above it.

Also `Sources/FlockCore/Mission/MissionBoard.swift:181` ranks groups by `sections.railOrder`; it receives `sections` from its caller, so the migrated call site already carries pins.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelPinTests -only-testing:FlockCoreTests/MissionBoardTests`
Then: `xcodebuild build-for-testing -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd`
Expected: tests pass; the app target builds.

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -A Sources Tests Flock.xcodeproj
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: the view model keeps pins, links them on every update, and pins and unpins" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: A pinned workspace's last tab closes without the workspace prompt, and pin names stay unique

**Files:**
- Modify: `Sources/FlockCore/Content/CloseConsequence.swift` (add `workspace(of:in:)` after `of(_:model:)`, line 55)
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`close(_:)` 1173-1183, `commitRename(_:for:)` 1449-1455)
- Test: `Tests/FlockCoreTests/SessionViewModelPinTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces: `public static func CloseConsequence.workspace(of: CloseSubject, in: SessionModel) -> WorkspaceID?`.

- [ ] **Step 1: Write the failing tests** (append to `SessionViewModelPinTests`)

```swift
func testClosingAPinnedWorkspacesLastTabAsksNothing() async {
    let (viewModel, _) = viewModel()
    viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
    await viewModel.closeTab(TabID(rawValue: "w1:t1"))
    XCTAssertNotNil(viewModel.pendingClose, "an ordinary workspace still asks")
    viewModel.cancelPendingClose()
    viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
    await viewModel.closeTab(TabID(rawValue: "w1:t1"))
    XCTAssertNil(viewModel.pendingClose)
}

func testRenamingAPinnedWorkspaceToAnotherPinsNameIsRefused() async {
    var notices: [String] = []
    let (viewModel, _) = viewModel(notices: { notices.append($0) })
    viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
    viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
    viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
    await viewModel.commitRename("ACME", for: .workspace(WorkspaceID(rawValue: "w2")))
    XCTAssertEqual(notices, ["A pinned workspace is already called \"ACME\"."])
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelPinTests`
Expected: the two new tests fail (`pendingClose` is set; no notice).

- [ ] **Step 3: Implement**

`CloseConsequence`:

```swift
public static func workspace(of subject: CloseSubject, in model: SessionModel) -> WorkspaceID? {
    switch subject {
    case .pane(let pane): model.panes[pane]?.workspaceID
    case .tab(let tab): workspace(holding: tab, in: model)
    }
}
```

`SessionViewModel.close(_:)`, replace `let consequence = CloseConsequence.of(subject, model: model)` with:

```swift
var consequence = CloseConsequence.of(subject, model: model)
// A pinned workspace outlives its last tab, so closing it costs no place.
if case .closesWorkspace = consequence,
   let workspace = CloseConsequence.workspace(of: subject, in: model), pins.pin(linkedTo: workspace) != nil {
    consequence = .subjectOnly
}
```

`commitRename(_:for:)`, at the top:

```swift
if case .workspace(let workspace) = target, let pin = pins.pin(linkedTo: workspace) {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if pins.isNameTaken(name, except: pin.id) {
        noticeSink("A pinned workspace is already called \"\(name)\".")
        cancelRename()
        return
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelPinTests -only-testing:FlockCoreTests/CloseConsequenceTests`
Expected: pass. (If `CloseConsequenceTests` does not exist, drop that flag.)

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -u
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: a pinned workspace's last tab closes without the workspace prompt; pin names stay unique" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Reopening an empty pin

**Files:**
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`create(_:_:label:)` 1576-1586 returns the created tab; new `reopen(_:)`; init gains `folderExists`)
- Test: `Tests/FlockCoreTests/SessionViewModelTests.swift` (append, so the file's private `StubCreateCommandClient`, `FakePlanExecutor`, `NoticeRecorder`, `makeModel()` are in scope)

**Interfaces:**
- Consumes: Tasks 1, 3.
- Produces: `public func reopen(_ id: PinID) async`; init param `folderExists: @escaping @Sendable (String) -> Bool = SessionViewModel.directoryExists` appended last; `public nonisolated static func directoryExists(_ path: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testReopeningAnEmptyPinCreatesInItsFolderRenamesAndLinks() async {
    let client = StubCreateCommandClient(workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1")
    let executor = FakePlanExecutor()
    let viewModel = SessionViewModel(client: client, planExecutor: executor, folderExists: { _ in true })
    viewModel.update(model: makeModel(), connection: .live)
    let workspace = viewModel.model!.workspaces[0].workspaceID
    viewModel.pin(workspace: workspace)
    let pin = viewModel.pins.pins[0]
    var gone = makeModel()
    gone.workspaces.removeAll()
    viewModel.update(model: gone, connection: .live)

    await viewModel.reopen(pin.id)

    let calls = await client.calls
    XCTAssertEqual(calls.map(\.method), ["workspace.create"])
    XCTAssertEqual(stringParam(calls[0].params, "cwd"), pin.folder)
    XCTAssertEqual(boolParam(calls[0].params, "focus"), true)
    XCTAssertEqual(executor.executedPlans.map(\.ops), [[.renameWorkspace(WorkspaceID(rawValue: "w9"), pin.name)]])
    XCTAssertEqual(viewModel.pins.pin(pin.id)?.workspace, WorkspaceID(rawValue: "w9"))
}

@MainActor
func testReopeningAPinWhoseFolderIsGoneOpensInHomeWithANotice() async {
    let client = StubCreateCommandClient(workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1")
    let notices = NoticeRecorder()
    let viewModel = SessionViewModel(
        client: client, planExecutor: FakePlanExecutor(), noticeSink: { notices.record($0) },
        homeDirectory: "/Users/acme", folderExists: { _ in false }
    )
    viewModel.update(model: makeModel(), connection: .live)
    viewModel.pin(workspace: viewModel.model!.workspaces[0].workspaceID)
    let pin = viewModel.pins.pins[0]
    var gone = makeModel()
    gone.workspaces.removeAll()
    viewModel.update(model: gone, connection: .live)

    await viewModel.reopen(pin.id)

    let calls = await client.calls
    XCTAssertEqual(stringParam(calls[0].params, "cwd"), "/Users/acme")
    XCTAssertEqual(notices.messages, ["\"\(pin.name)\" opened in your home folder: its folder is gone. Change Folder\u{2026} picks another."])
}

@MainActor
func testASecondReopenWhileOneIsInFlightSendsNothing() async {
    let client = RecordingCommandClient()
    let viewModel = SessionViewModel(client: client, planExecutor: FakePlanExecutor(), folderExists: { _ in true })
    viewModel.update(model: makeModel(), connection: .live)
    viewModel.pin(workspace: viewModel.model!.workspaces[0].workspaceID)
    let pin = viewModel.pins.pins[0]
    var gone = makeModel()
    gone.workspaces.removeAll()
    viewModel.update(model: gone, connection: .live)

    await client.hold()
    async let first: Void = viewModel.reopen(pin.id)
    await Task.yield()
    await viewModel.reopen(pin.id)
    await client.releaseNext()
    await first

    let calls = await client.calls
    XCTAssertEqual(calls.map(\.method), ["workspace.create"])
}

@MainActor
func testReopeningALinkedPinDoesNothing() async {
    let client = RecordingCommandClient()
    let viewModel = SessionViewModel(client: client, folderExists: { _ in true })
    viewModel.update(model: makeModel(), connection: .live)
    viewModel.pin(workspace: viewModel.model!.workspaces[0].workspaceID)
    await viewModel.reopen(viewModel.pins.pins[0].id)
    let calls = await client.calls
    XCTAssertEqual(calls.count, 0)
}
```

Check `RecordingCommandClient`'s `hold()`/`releaseNext()` names in the file (lines 4-26) and match them. If `homeDirectory` is not the init parameter's label, use the real label.

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelTests`
Expected: build failure, `extra argument 'folderExists' in call`.

- [ ] **Step 3: Implement**

Change `create` to return what it made, keeping current callers working:

```swift
@discardableResult
private func create(_ method: String, _ params: [String: JSONValue], label: String) async -> CreatedTab? {
    do {
        let data = try await client.requestRaw(method, params)
        guard let created = Self.extractCreatedTab(data) else { return nil }
        selectedWorkspaceID = created.workspaceID
        selectedTabID = created.tabID
        landIn(pane: created.rootPaneID)
        return created
    } catch {
        noticeSink("\(label) failed: \(Self.describe(error))")
        return nil
    }
}
```

(Keep the existing body's statements; only add the return values.)

Init: append `folderExists: @escaping @Sendable (String) -> Bool = SessionViewModel.directoryExists`, store as `@ObservationIgnored private let folderExists: @Sendable (String) -> Bool`.

```swift
public nonisolated static func directoryExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}

@ObservationIgnored private var reopening: Set<PinID> = []

/// A fresh shell in the pin's folder, renamed to the pin and linked to it by
/// the id the create returns, never by name.
public func reopen(_ id: PinID) async {
    guard let pin = pins.pin(id), pin.workspace == nil, !reopening.contains(id) else { return }
    reopening.insert(id)
    defer { reopening.remove(id) }
    let folderIsThere = folderExists(pin.folder)
    let params: [String: JSONValue] = [
        "focus": .bool(true), "cwd": .string(folderIsThere ? pin.folder : homeDirectory),
    ]
    guard let created = await create("workspace.create", params, label: "Reopen \(pin.name)") else { return }
    pins.link(id, to: created.workspaceID)
    await run(OpPlan(ops: [.renameWorkspace(created.workspaceID, pin.name)], label: "Rename workspace"), recordsUndo: false)
    if !folderIsThere {
        noticeSink("\"\(pin.name)\" opened in your home folder: its folder is gone. Change Folder\u{2026} picks another.")
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/SessionViewModelTests`
Expected: pass, including the existing create tests.

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -u
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: an empty pin reopens as a fresh shell in its folder" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Workspace menus for pins

**Files:**
- Modify: `Sources/FlockCore/Menus/ChromeMenuModel.swift` (`WorkspaceMenuAction` 27-30, `WorkspaceMenuModel` 68-76, `perform` 105-115; add `EmptyPinMenuAction`, `EmptyPinMenuModel`)
- Create: `Sources/Flock/Views/FolderPanel.swift`
- Modify: `Sources/Flock/Views/WorkspaceMark.swift` (`WorkspaceMenu` 17-52; add `emptyPinMenu`)
- Modify: `Sources/Flock/Views/Settings/StartingFolderSettingsSection.swift:53-65` to use `FolderPanel`
- Test: `Tests/FlockCoreTests/ChromeMenuModelTests.swift` (or whichever file tests `WorkspaceMenuModel`; grep `WorkspaceMenuModel.entries` in Tests)

**Interfaces:**
- Consumes: Task 3 (`pin(workspace:)`, `unpin(_:)`, `removePin(_:)`, `setPinFolder(_:to:)`, `pins`).
- Produces:
  - `WorkspaceMenuAction` cases `.rename, .pin, .unpin, .changeFolder, .close`.
  - `WorkspaceMenuModel.entries(for:model:isPinned: Bool = false)`.
  - `enum EmptyPinMenuAction { rename, changeFolder, remove }` and `EmptyPinMenuModel.entries() -> [ChromeMenuEntry<EmptyPinMenuAction>]`.
  - `enum FolderPanel { @MainActor static func choose(current: String?, message: String) -> String? }`.
  - View modifiers `workspaceMenu(viewModel:workspace:key:changeSymbol:)` (unchanged signature) and `emptyPinMenu(viewModel:pin:beginRename:changeSymbol:)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testAnOrdinaryWorkspaceMenuOffersPinAndClose() {
    let entries = WorkspaceMenuModel.entries(for: workspace, model: model)
    XCTAssertEqual(entries.map(\.label), ["Rename", "Pin", "Close"])
}

func testAPinnedWorkspaceMenuOffersNoClose() {
    let entries = WorkspaceMenuModel.entries(for: workspace, model: model, isPinned: true)
    XCTAssertEqual(entries.map(\.label), ["Rename", "Change Folder\u{2026}", "Unpin"])
}

func testAnEmptyPinMenuOffersRemove() {
    XCTAssertEqual(EmptyPinMenuModel.entries().map(\.label), ["Rename", "Change Folder\u{2026}", "Remove"])
}
```

(`workspace` and `model` are the test file's existing fixtures for the workspace menu; reuse them.)

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/ChromeMenuModelTests`
Expected: build failure, `extra argument 'isPinned'`.

- [ ] **Step 3: Implement the models**

```swift
public enum WorkspaceMenuAction: Equatable, Sendable {
    case rename
    case pin
    case unpin
    case changeFolder
    case close
}

public enum EmptyPinMenuAction: Equatable, Sendable {
    case rename
    case changeFolder
    case remove
}

public enum WorkspaceMenuModel {
    public static func entries(for workspace: WorkspaceID, model: SessionModel, isPinned: Bool = false) -> [ChromeMenuEntry<WorkspaceMenuAction>] {
        guard model.workspaces.contains(where: { $0.workspaceID == workspace }) else { return [] }
        let rename = ChromeMenuEntry(label: "Rename", action: WorkspaceMenuAction.rename, accessibilityIdentifier: "flock.workspace.menu.rename")
        guard !isPinned else {
            return [
                rename,
                ChromeMenuEntry(label: "Change Folder\u{2026}", action: .changeFolder, accessibilityIdentifier: "flock.workspace.menu.changeFolder"),
                ChromeMenuEntry(label: "Unpin", action: .unpin, accessibilityIdentifier: "flock.workspace.menu.unpin"),
            ]
        }
        return [
            rename,
            ChromeMenuEntry(label: "Pin", action: .pin, accessibilityIdentifier: "flock.workspace.menu.pin"),
            ChromeMenuEntry(label: "Close", action: .close, accessibilityIdentifier: "flock.workspace.menu.close"),
        ]
    }
}

public enum EmptyPinMenuModel {
    public static func entries() -> [ChromeMenuEntry<EmptyPinMenuAction>] {
        [
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.pin.menu.rename"),
            ChromeMenuEntry(label: "Change Folder\u{2026}", action: .changeFolder, accessibilityIdentifier: "flock.pin.menu.changeFolder"),
            ChromeMenuEntry(label: "Remove", action: .remove, accessibilityIdentifier: "flock.pin.menu.remove"),
        ]
    }
}
```

`WorkspaceMenuAction.perform`:

```swift
switch self {
case .rename: viewModel.beginRename(.workspace(workspaceID))
case .pin: viewModel.pin(workspace: workspaceID)
case .unpin: if let pin = viewModel.pins.pin(linkedTo: workspaceID) { viewModel.unpin(pin.id) }
// The folder panel is AppKit's; the view runs it and calls `setPinFolder`.
case .changeFolder: break
case .close: await viewModel.closeWorkspace(workspaceID)
}
```

Keep the doc comment above `WorkspaceMenuModel` accurate: replace "flock mirrors the two it has a capability for" with a sentence saying flock adds Pin, and that a pinned workspace offers Change Folder... and Unpin in place of Close.

- [ ] **Step 4: Implement the views**

`Sources/Flock/Views/FolderPanel.swift`:

```swift
import AppKit

enum FolderPanel {
    @MainActor
    static func choose(current: String?, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        if let current { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
```

Use it from `StartingFolderSettingsSection.chooseFolder(for:)` in place of its inline panel, keeping that section's message text.

In `WorkspaceMark.swift`, `WorkspaceMenu.body`: build entries with `isPinned: viewModel.pins.pin(linkedTo: workspace) != nil`, put Change Symbol... directly after Rename, and route `.changeFolder` to the panel:

```swift
ForEach(WorkspaceMenuModel.entries(for: workspace, model: model, isPinned: pin != nil), id: \.accessibilityIdentifier) { entry in
    Button(entry.label) {
        if entry.action == .changeFolder, let pin {
            if let folder = FolderPanel.choose(current: pin.folder, message: "Where \"\(pin.name)\" opens") {
                viewModel.setPinFolder(pin.id, to: folder)
            }
        } else {
            Task { await entry.action.perform(workspaceID: workspace, on: viewModel) }
        }
    }
    .accessibilityIdentifier(entry.accessibilityIdentifier)
    if entry.action == .rename, let changeSymbol {
        Button("Change Symbol\u{2026}", action: changeSymbol)
            .accessibilityIdentifier("flock.identity.symbol.menu")
    }
}
```

with `let pin = viewModel.pins.pin(linkedTo: workspace)` computed at the top of the `contextMenu` builder.

Add the empty pin's menu beside it:

```swift
private struct EmptyPinMenu: ViewModifier {
    let viewModel: SessionViewModel
    let pin: PinnedWorkspace
    let beginRename: () -> Void
    let changeSymbol: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            ForEach(EmptyPinMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                Button(entry.label) {
                    switch entry.action {
                    case .rename: beginRename()
                    case .changeFolder:
                        if let folder = FolderPanel.choose(current: pin.folder, message: "Where \"\(pin.name)\" opens") {
                            viewModel.setPinFolder(pin.id, to: folder)
                        }
                    case .remove: viewModel.removePin(pin.id)
                    }
                }
                .accessibilityIdentifier(entry.accessibilityIdentifier)
                if entry.action == .rename {
                    Button("Change Symbol\u{2026}", action: changeSymbol)
                        .accessibilityIdentifier("flock.identity.symbol.menu")
                }
            }
        }
    }
}

extension View {
    func emptyPinMenu(viewModel: SessionViewModel, pin: PinnedWorkspace, beginRename: @escaping () -> Void, changeSymbol: @escaping () -> Void) -> some View {
        modifier(EmptyPinMenu(viewModel: viewModel, pin: pin, beginRename: beginRename, changeSymbol: changeSymbol))
    }
}
```

- [ ] **Step 5: Verify and commit**

Run: `xcodegen`, then the menu tests from Step 2, then `xcodebuild build-for-testing -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd`.
Expected: tests pass, app builds.

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -A Sources Tests Flock.xcodeproj
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: workspace menus pin, unpin and change a pin's folder; a pinned workspace offers no Close" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Dropping onto PINNED

**Files:**
- Modify: `Sources/FlockCore/Mutations/OpPlan.swift:5-23` (new `DropTarget` and `DragSubject` cases)
- Modify: `Sources/FlockCore/Drag/DropResolver.swift` (`PinItemFrame`; `DropSurfaces` 137-175; `resolveDropTarget` 205-230; `resolveRail` 324-336; new `resolvePinned`)
- Modify: every exhaustive `switch` over `DragSubject` the compiler flags (resolver, `GesturePlanner`, `DragCoordinator`, ghost/label code): `.pin` resolves to no target / plans nothing outside the rail
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`perform(subject:target:board:)` 1303, thread `pinned` to the planner)
- Test: `Tests/FlockCoreTests/DropResolverTests.swift`, `Tests/FlockCoreTests/SessionViewModelPinTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3.
- Produces:
  - `DropTarget.pinnedRail(insertIndex: Int)`, `DragSubject.pin(PinID)`.
  - `public struct PinItemFrame: Equatable, Sendable { id: PinID; workspace: WorkspaceID?; frame: CGRect }`.
  - `DropSurfaces` init gains trailing `pinnedFrames: [PinItemFrame] = []`, `pinnedFrame: CGRect? = nil`.

- [ ] **Step 1: Write the failing tests**

`DropResolverTests` (reuse the file's existing `CanvasGeometry` fixture to build `DropSurfaces`):

```swift
func testAWorkspaceOverPinnedResolvesToAnInsertIndexThere() {
    let pins = [
        PinItemFrame(id: PinID(rawValue: "p1"), workspace: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 0, y: 0, width: 200, height: 28)),
        PinItemFrame(id: PinID(rawValue: "p2"), workspace: nil, frame: CGRect(x: 0, y: 30, width: 200, height: 28)),
    ]
    let surfaces = DropSurfaces(
        canvas: canvas, stripWorkspace: WorkspaceID(rawValue: "w1"), tabFrames: [], workspaceFrames: [],
        newTabZone: nil, newWorkspaceZone: nil, pinnedFrames: pins, pinnedFrame: CGRect(x: 0, y: 0, width: 200, height: 60)
    )
    XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 10, y: 40), dragging: .workspace(WorkspaceID(rawValue: "w5")), surfaces: surfaces), .pinnedRail(insertIndex: 1))
    XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 10, y: 50), dragging: .pin(PinID(rawValue: "p1")), surfaces: surfaces), .pinnedRail(insertIndex: 2))
    XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 10, y: 5), dragging: .pane(PaneID(rawValue: "w5:p1")), surfaces: surfaces), .workspaceThumbnail(WorkspaceID(rawValue: "w1")))
    XCTAssertNil(resolveDropTarget(at: CGPoint(x: 10, y: 35), dragging: .pane(PaneID(rawValue: "w5:p1")), surfaces: surfaces), "an empty pin holds no panes")
}
```

`SessionViewModelPinTests`:

```swift
func testDroppingAWorkspaceOnPinnedPinsItAndAPinOnWorkspacesUnpinsIt() async {
    let (viewModel, _) = viewModel()
    viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
    _ = await viewModel.perform(subject: .workspace(WorkspaceID(rawValue: "w2")), target: .pinnedRail(insertIndex: 0))
    XCTAssertEqual(viewModel.pins.pins.map(\.name), ["web"])
    _ = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 0))
    XCTAssertEqual(viewModel.pins.pins, [])
}

func testDroppingAPinWithinPinnedReorders() async {
    let (viewModel, _) = viewModel()
    viewModel.update(model: model([("w1", "acme"), ("w2", "web")]), connection: .live)
    viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
    viewModel.pin(workspace: WorkspaceID(rawValue: "w2"))
    _ = await viewModel.perform(subject: .pin(viewModel.pins.pins[1].id), target: .pinnedRail(insertIndex: 0))
    XCTAssertEqual(viewModel.pins.pins.map(\.name), ["web", "acme"])
}

func testAnEmptyPinCannotLeavePinned() async {
    let (viewModel, _) = viewModel()
    viewModel.update(model: model([("w1", "acme")]), connection: .live)
    viewModel.pin(workspace: WorkspaceID(rawValue: "w1"))
    viewModel.update(model: model([]), connection: .live)
    let outcome = await viewModel.perform(subject: .pin(viewModel.pins.pins[0].id), target: .workspaceRail(insertIndex: 0))
    XCTAssertEqual(outcome, .noOp)
    XCTAssertEqual(viewModel.pins.pins.count, 1)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/DropResolverTests -only-testing:FlockCoreTests/SessionViewModelPinTests`
Expected: build failure, `type 'DropTarget' has no member 'pinnedRail'`.

- [ ] **Step 3: Implement**

`OpPlan.swift`: add `case pinnedRail(insertIndex: Int)` to `DropTarget` and `case pin(PinID)` to `DragSubject` with the doc line `/// A pinned workspace, live or empty, moving within or out of PINNED.`

`DropResolver.swift`:

```swift
public struct PinItemFrame: Equatable, Sendable {
    public let id: PinID
    /// nil for an empty pin, which no pane or tab can land on.
    public let workspace: WorkspaceID?
    public let frame: CGRect

    public init(id: PinID, workspace: WorkspaceID?, frame: CGRect) {
        self.id = id
        self.workspace = workspace
        self.frame = frame
    }
}
```

Add `public let pinnedFrames: [PinItemFrame]` and `public let pinnedFrame: CGRect?` to `DropSurfaces`, as trailing init parameters with defaults `[]` and `nil`.

In `resolveDropTarget`, after `resolveZone` and before the rail check:

```swift
if let pinnedBounds = surfaces.pinnedFrame ?? unionRect(surfaces.pinnedFrames.map(\.frame)), pinnedBounds.contains(point) {
    return resolvePinned(at: point, dragging: dragging, surfaces: surfaces)
}
```

```swift
private func resolvePinned(at point: CGPoint, dragging: DragSubject, surfaces: DropSurfaces) -> DropTarget? {
    switch dragging {
    case .pane, .tab:
        guard surfaces.railViewport?.contains(point) ?? true,
              let workspace = surfaces.pinnedFrames.first(where: { $0.frame.contains(point) })?.workspace
        else { return nil }
        return .workspaceThumbnail(workspace)
    case .workspace, .workspaces, .pin:
        let centers = surfaces.pinnedFrames.map(\.frame.midY)
        let y = clamp(point.y, to: surfaces.railViewport.map { ($0.minY, $0.maxY) })
        return .pinnedRail(insertIndex: insertIndex(of: y, centers: centers))
    }
}
```

In `resolveRail`, change `case .workspace, .workspaces:` to `case .workspace, .workspaces, .pin:`. In `resolveGrid`, `resolveStrip`, `resolveZone` and any other switch, `.pin` returns `nil`.

`SessionViewModel.perform(subject:target:board:)`, first lines:

```swift
if let outcome = await performPinDrop(subject: subject, target: target, board: board) { return outcome }
```

```swift
/// Pin drops are flock's own bookkeeping, so they never reach the planner,
/// except a live pin dropped among WORKSPACES, which also moves it in herdr.
private func performPinDrop(subject: DragSubject, target: DropTarget, board: BoardWorkspaceNames?) async -> DragOutcome? {
    switch (subject, target) {
    case let (.workspace(workspace), .pinnedRail(index)):
        if let pinned = pins.pin(linkedTo: workspace) { movePin(pinned.id, toInsertIndex: index) } else { pin(workspace: workspace, at: index) }
        return .committed
    case let (.workspaces(block), .pinnedRail(index)):
        for (offset, workspace) in block.enumerated() { pin(workspace: workspace, at: index + offset) }
        return .committed
    case let (.pin(id), .pinnedRail(index)):
        movePin(id, toInsertIndex: index)
        return .committed
    case let (.pin(id), .workspaceRail(index)):
        guard let workspace = pins.pin(id)?.workspace else { return .noOp }
        unpin(id)
        return await perform(subject: .workspace(workspace), target: .workspaceRail(insertIndex: index), board: board)
    case (.pin, _), (_, .pinnedRail):
        return .noOp
    default:
        return nil
    }
}
```

Where `perform` hands `board` to the planner, also hand `pinned: Set(pins.pins.compactMap(\.workspace))` (the parameter Task 2 threaded).

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/DropResolverTests -only-testing:FlockCoreTests/SessionViewModelPinTests -only-testing:FlockCoreTests/GesturePlannerTests`
Then `xcodebuild build-for-testing -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd`.
Expected: pass and build.

- [ ] **Step 5: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -u
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "pins: PINNED is a drop target: pin, reorder and unpin by dragging" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The PINNED section in the rail

**Files:**
- Modify: `Sources/Flock/Views/WorkspaceRail.swift` (body 32-194; new `pinnedSection`; new `EmptyPinRow`)
- Modify: `Sources/Flock/Drag/DragCoordinator.swift` (pin frames, pin order, pin displacement, pin drag subject, `DropSurfaces` construction)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift` (`Rail.sectionGap` if no gap constant exists between sections)
- Test: `Tests/FlockChromeRender/PinnedRailRenderTests.swift` (create)

**Interfaces:**
- Consumes: Tasks 3, 6, 7 (`viewModel.pins`, `reopen(_:)`, `renamePin(_:to:)`, `emptyPinMenu`, `workspaceMenu`, `DragSubject.pin`, `PinItemFrame`).
- Produces: the rail's PINNED section; `DragCoordinator.setPinFrame(_:for:workspace:)`, `setPinnedOrder(_:)`, `pinDisplacement(at:)`, `isDragging(pin:)`, `pinDragSubject(_:)`.

This task wires views into the custom drag system. It needs the most capable model.

- [ ] **Step 1: DragCoordinator learns pinned rows**

Mirror the workspace-row machinery for pins, reading how it works today: `setWorkspaceOrder(_:)` (408), `setWorkspaceFrame(_:for:)` (427), `workspaceDisplacement(at:)` (1326), `isDragging(workspace:)` (1229) and where `workspaceFrames` are packed into `DropSurfaces`.
- Add `setPinnedOrder(_ order: [PinID])`, `setPinFrame(_ frame: CGRect, for id: PinID, workspace: WorkspaceID?)`, `setPinnedRegion(_ frame: CGRect)`, `pinDisplacement(at index: Int) -> CGFloat`, `isDragging(pin: PinID) -> Bool`.
- Frames freeze during a drag exactly as workspace frames do.
- Pass `pinnedFrames:` (in pinned order) and `pinnedFrame:` into every `DropSurfaces(...)` the coordinator builds for the main window.
- `pinnedFrame` is the PINNED section's own region, so a drop on its heading or between rows still lands in PINNED.
- A pin drag's ghost title is the pin's name; the drag subject is `.pin(id)`.

- [ ] **Step 2: The section**

In `WorkspaceRail.body`, inside the scrolling `VStack`, before the WORKSPACES rows, draw the section when `viewModel.pins.pins` is not empty:

```swift
if let sections, !sections.pinned.isEmpty {
    railHeading("PINNED")
    ForEach(Array(sections.pinned.enumerated()), id: \.element.pin.id) { index, row in
        pinnedRow(row, index: index, sections: sections)
            .offset(y: drag.pinDisplacement(at: index))
            .reportsFrame(in: DragSpace.railContent) { drag.setPinFrame($0, for: row.pin.id, workspace: row.record?.workspaceID) }
    }
    railHeading("WORKSPACES")
}
```

Move the existing `"WORKSPACES"` heading into the scroll content so both headings scroll alike, and draw it at the top only when there are no pins. Extract `railHeading(_:)` from the current heading code (35-41) with identical font, tracking, colour and padding. Report the PINNED block's frame with `drag.setPinnedRegion(_:)` from its container, and call `drag.setPinnedOrder(sections.pinned.map(\.pin.id))` in the same `.onAppear`/`.onChange` that sets the workspace order.

`pinnedRow`:
- A linked pin draws the same `WorkspaceRow` the WORKSPACES rows use, with the same tap, drag (subject `.pin(row.pin.id)`), rename editor and `.workspaceMenu(viewModel:workspace:key:changeSymbol:)`.
- Its `markKey` is `row.pin.identityKey`, and its picker binding is keyed by the workspace id.
- An empty pin draws `EmptyPinRow`.

```swift
struct EmptyPinRow: View {
    let theme: Theme
    let pin: PinnedWorkspace
    var isRenaming = false
    var pickingSymbol: Binding<Bool>?
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    var body: some View {
        HStack(spacing: ChromeMetrics.WorkspaceRow.spacing) {
            // No dot: the dot only ever means status, and nothing runs here.
            Color.clear.frame(width: ChromeMetrics.WorkspaceRow.statusDot, height: ChromeMetrics.WorkspaceRow.statusDot)
            WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.WorkspaceRow.mark, picking: pickingSymbol)
                .opacity(ChromeMetrics.WorkspaceRow.emptyPinMarkOpacity)
            if isRenaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.workspaceName(selected: false), initialText: pin.name,
                    accessibilityIdentifier: "flock.rail.pin.rename.\(pin.id.rawValue)",
                    onCommit: onCommitRename, onCancel: onCancelRename
                )
            } else {
                Text(pin.name)
                    .font(ChromeType.workspaceName(selected: false))
                    .foregroundStyle(theme.textLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .modifier(RailRowChrome(theme: theme, showsFill: false))
    }
}
```

Add `static let emptyPinMarkOpacity: Double = 0.6` to `ChromeMetrics.WorkspaceRow`.

The rail holds `@State private var renamingPin: PinID?` for the empty row's editor.
- A plain click on an empty row calls `Task { await viewModel.reopen(pin.id) }`.
- A double click sets `renamingPin`, using `NSEvent.chromeRowClick` as `handleClick(on:)` does.
- Commit calls `viewModel.renamePin(pin.id, to:)` and clears `renamingPin`; cancel clears it.
- `.emptyPinMenu(viewModel:pin:beginRename:changeSymbol:)` supplies the menu.
- The accessibility identifier is `flock.rail.pin.\(pin.id.rawValue)`.

- [ ] **Step 3: Render test**

Create `Tests/FlockChromeRender/PinnedRailRenderTests.swift`. Follow the setup in `WorkspaceRailNewWorkspaceZoneHitTestTests.swift` (31-43) for the environment stores. The model has workspaces `acme` and `web`:

- the view model is built with `pinnedWorkspaceDefaults: nil` and an identity store on a fresh suite;
- pin `web` (`viewModel.pin(workspace:)`), then pin `acme` and update with a model lacking `acme`, so it is an empty pin;
- render the rail at 280x400 in `tokyo-night` and `tokyo-night-day`;
- write `pinned-rail-dark.png` and `pinned-rail-light.png` to `FLOCK_CHROME_RENDER_DIR` when set.

Assert:
- the PINNED heading sits above the WORKSPACES heading;
- the empty pin's name pixel is `textLabel`, not `textStrong`;
- the empty row has no status-dot colour in the dot's slot.

Run it with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy/build/render`. Open both PNGs and look: check headings, alignment of the empty row with live rows, dimming, and that nothing overlaps. Say plainly what looks wrong and fix it.

Also run `ChromeRenderTests/testEveryChromeRolePaintsItsExactHex` (no pins, its rail samples must not move) and `WorkspaceRailNewWorkspaceZoneHitTestTests`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -A Sources Tests Flock.xcodeproj
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "rail: a PINNED section above WORKSPACES; an empty pin reopens on click" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The workspace switcher lists pins

**Files:**
- Modify: `Sources/FlockCore/Switcher/RecentsSwitcher.swift:108` (`candidates`)
- Modify: `Sources/FlockCore/Rail/PinnedWorkspaces.swift` (switcher id helpers)
- Modify: `Sources/Flock/Switcher/SwitcherView.swift:19-33`
- Test: `Tests/FlockCoreTests/WorkspaceSwitcherTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 5.
- Produces:
  - `PinnedWorkspace.switcherID: WorkspaceID` and `PinID.init?(switcherID: WorkspaceID)`.
  - `WorkspaceSwitcher.candidates(_:current:pins: [PinnedWorkspace] = [])`.

- [ ] **Step 1: Write the failing test**

```swift
func testPinsLeadTheCandidatesAndAnEmptyPinHasASwitcherID() {
    let live = PinnedWorkspace(id: PinID(rawValue: "p1"), name: "web", folder: "/web", workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "web", confirmed: true)
    let empty = PinnedWorkspace(id: PinID(rawValue: "p2"), name: "notes", folder: "/notes", workspace: nil, syncedLabel: nil, confirmed: false)
    let records = [
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: "w1"), label: "acme", number: 1, activeTabID: TabID(rawValue: "w1:t1"), agentStatus: .idle),
        WorkspaceRecord(workspaceID: WorkspaceID(rawValue: "w2"), label: "web", number: 2, activeTabID: TabID(rawValue: "w2:t1"), agentStatus: .idle),
    ]
    let ids = WorkspaceSwitcher.candidates(records, current: nil, pins: [live, empty])
    XCTAssertEqual(ids.map(\.rawValue), ["w2", "pin:p2", "w1"])
    XCTAssertEqual(PinID(switcherID: ids[1]), PinID(rawValue: "p2"))
    XCTAssertNil(PinID(switcherID: ids[0]))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd -only-testing:FlockCoreTests/WorkspaceSwitcherTests`
Expected: build failure, `extra argument 'pins'`.

- [ ] **Step 3: Implement**

In `PinnedWorkspaces.swift`:

```swift
extension PinnedWorkspace {
    /// The switcher lists by workspace id; an empty pin has none, so it takes
    /// one herdr never issues.
    public var switcherID: WorkspaceID { WorkspaceID(rawValue: "pin:\(id.rawValue)") }
}

extension PinID {
    public init?(switcherID: WorkspaceID) {
        guard switcherID.rawValue.hasPrefix("pin:") else { return nil }
        self.init(rawValue: String(switcherID.rawValue.dropFirst(4)))
    }
}
```

`candidates`:

```swift
public static func candidates(_ workspaces: [WorkspaceRecord], current: WorkspaceID?, pins: [PinnedWorkspace] = []) -> [WorkspaceID] {
    let pinned = pins.map { $0.workspace ?? $0.switcherID }
    let linked = Set(pins.compactMap(\.workspace))
    let rest = workspaces
        .filter { !linked.contains($0.workspaceID) }
        .filter { $0.workspaceID == current || !HerdWorkspace.isHerd(label: $0.label) }
        .map(\.workspaceID)
    return pinned + rest
}
```

`SwitcherView.swift`:
- `candidates:` passes `pins: viewModel.pins.pins`.
- `row:` first tries `PinID(switcherID: id).flatMap { viewModel.pins.pin($0) }.map { SwitcherRow(status: .unknown, label: $0.name, count: 0) }`, else the existing record lookup.
- `go:` becomes `{ id in Task { if let pin = PinID(switcherID: id) { await viewModel.reopen(pin) } else { await viewModel.jumpToHerdr(workspace: id) } } }`.

- [ ] **Step 4: Run to verify it passes, then commit**

Run the Step 2 command plus `xcodebuild build-for-testing -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath build/dd`.

```bash
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy add -u
Scripts/checks.sh
git -C /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/eager-daisy commit -m "switcher: pins lead the list and an empty pin reopens from it" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
