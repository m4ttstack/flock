# Top-bar Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a one-tab pinned workspace live in the title bar as an icon that opens it live in an overlay, hidden from every other workspace list.

**Architecture:** A top-bar workspace is a `PinnedWorkspace` with `placement == .topBar`. `SessionViewModel` hides top-bar workspaces through the same one filter that hides flock-owned ones, while pin bookkeeping reads a `userModel` that keeps them. The title bar draws a strip of cells; a window-level overlay is a `ChromeModal`, the modal shell Task 1 extracts from the rt modal for every modal to share, holding the workspace's active tab as `ModalTerminalPane` cells, sized per pin.

**Reuse rule:** the overlay adds no modal chrome of its own. Anything it needs that the rt modal also has (backdrop, card, title row, size control, close, hosted pane) comes from `Sources/Flock/Views/Modal/`; if something is missing there, add it there.

**Tech Stack:** Swift 6, SwiftUI, XCTest, xcodegen, libghostty surfaces.

**Spec:** `docs/superpowers/specs/2026-10-07-top-bar-workspaces-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host or ticket id anywhere, commit messages included. Fixtures use `acme`.
- No em or en dashes in code, comments, docs or commits (`Scripts/checks.sh` fails on them).
- Comments state constraints the code cannot show; no narration, no decision history.
- Tests stay hermetic: no rt, herdr, herdr-chat or deck; stores take injected `UserDefaults` suites.
- Every build/test uses a scratch `-derivedDataPath` (below: `$DD`, e.g. `DD=$(mktemp -d)`).
- Run `xcodegen` after adding files; run `Scripts/checks.sh` after `git add`.
- Only targeted tests while iterating; the full suites once at the end.
- `XCTestCase.setUp`/`tearDown` are not main-actor: statics they read on a `@MainActor` test class must be `nonisolated`.
- A UI task is not done until its render is looked at in a dark and a light theme.
- Never quit, kill or launch Flock; hand over with `Scripts/dev-build.sh`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

Test commands (substitute the class):

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockCoreTests/<Class>
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockChromeRender/<Class>
```

## Review Focus

1. **A top-bar pin reconciled against the filtered model empties itself.** `pins.reconcile` and `isOpen` must read `userModel`; otherwise the next update unlinks the pin and the next click creates a duplicate workspace. Test in Task 4.
2. **Moving the selected workspace to the top bar.** The main view must land on a neighbour (`CloseSelection`), never show an empty canvas or keep the hidden workspace selected. Test in Task 4.
3. **Pin indices after mixing placements.** A rail drop index counts rail pins only; a pin sitting in the top bar between two rail pins in the stored array must not shift where a rail drop lands. Test in Task 2.
4. **An empty top-bar pin clicked while herdr is slow.** The overlay must stay open on the loader until the link lands, and must not focus the new workspace in herdr or move the main selection. Test in Task 4.
5. **A top-bar workspace's symbol survives `WorkspaceIdentityStore.refresh`.** Leaving PINNED must not make `keepOnly` drop its key. Test in Task 3.

---

### Task 1: Extract the shared modal from the rt modal

The rt modal's shell (backdrop, sized card, title row with size control and close, a hosted terminal pane) moves to `Sources/Flock/Views/Modal/` under neutral names, and the rt modal becomes its first user. Behaviour and pixels stay the same. Every later modal, the top-bar overlay first, is built from these pieces.

**Files:**
- Create: `Sources/FlockCore/Modal/ModalSize.swift` (the enum from `Sources/FlockCore/Rt/RtModalSize.swift`, renamed)
- Modify: `Sources/FlockCore/Rt/RtModalSize.swift` (keeps `RtModalSizeStore` only, typed with `ModalSize`)
- Create: `Sources/Flock/Views/Modal/ChromeModal.swift`
- Create: `Sources/Flock/Views/Modal/ModalSizeControl.swift` (from `RtModalSizeControl`)
- Move: `Sources/Flock/Rt/RtModalPane.swift` to `Sources/Flock/Views/Modal/ModalTerminalPane.swift` (type `ModalTerminalPane`)
- Modify: `Sources/Flock/Rt/RtModalView.swift` (built on `ChromeModal`)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift` (`ChromeMetrics.Modal`; `ChromeMetrics.RtModal` keeps only rt's own)
- Modify: the `ChromeType` file (grep `rtModalTitle`): `rtModalTitle` and `rtModalClose` become `modalTitle` and `modalClose`
- Modify: `Tests/FlockCoreTests/RtModalSizeTests.swift`, `Tests/FlockChromeRender/RtModalChromeRenderTests.swift` (names only)

**Interfaces:**
- Produces:
  - `public enum ModalSize: String, CaseIterable, Sendable { case small, medium, large }` with `displayName`
  - `ChromeModal<Leading: View, Content: View, Footer: View>(theme:size:footerHeight:onSize:onDismiss:leading:content:footer:)`; `content` receives `(area: CGSize, scale: CGFloat)`, the terminal area inside the card
  - `ChromeModal.boxFrame(in:origin:scale:fraction:) -> CGRect` (moved from `RtModalView`)
  - `ModalSizeControl(theme:selected:onSelect:)`
  - `ModalTerminalPane(theme:viewModel:paneID:grid:surfaceSize:fontSizePoints:isFocused:command:onFocus:)` (same as `RtModalPane`)
  - `ChromeMetrics.Modal` with `sizeFraction(_:)`, `cornerRadius`, `darkBackdropOpacity`, `lightBackdropOpacity`, `shadowOpacity`, `shadowRadius`, `shadowY`, `paneInset`, `TitleRow`, `SizeControl`

- [ ] **Step 1: Capture the rt modal's pixels before the move**

```bash
mkdir -p /tmp/flock-modal/before /tmp/flock-modal/after
TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=/tmp/flock-modal/before xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockChromeRender/RtModalChromeRenderTests
ls /tmp/flock-modal/before
```

Expected: PASS, PNGs written. If `RtModalChromeRenderTests` writes under another variable, use the one it reads (grep `RENDER_DIR` in it).

- [ ] **Step 2: Move the size enum**

`Sources/FlockCore/Modal/ModalSize.swift`:

```swift
import Foundation

/// How much of the area under it a modal's card takes.
public enum ModalSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
```

Delete the enum from `RtModalSize.swift` and replace `RtModalSize` with `ModalSize` across `Sources` and `Tests` (`grep -rl RtModalSize Sources Tests`; leave `RtModalSizeStore` and `RtModalSizeTests` named as they are). The stored values are the same raw strings, so saved sizes still load.

- [ ] **Step 3: Metrics and fonts**

In `ChromeMetrics.swift`, rename `enum RtModal` to `enum Modal`, then move `TitleRow.backDividerSize`, `TitleRow.backHoverPadding` and `Strip` into a new, smaller `enum RtModal` beside it:

```swift
    /// The rt modal's own pieces on top of the shared `Modal`.
    enum RtModal {
        static let backDividerSize = CGSize(width: 1, height: 12)
        static let backHoverPadding: CGFloat = 5

        enum Strip {
            static let height: CGFloat = 26
            static let horizontalPadding: CGFloat = 12
        }
    }
```

`SizeControl.glyphSize(_:)` takes `ModalSize`. Rename the two fonts and fix every reference the compiler names.

- [ ] **Step 4: The shared views**

`ModalSizeControl.swift`: `RtModalSizeControl` moved verbatim, renamed, reading `ChromeMetrics.Modal.SizeControl`, with accessibility identifiers `flock.modal.size.<raw>`. (The rt tests that look up `flock.rt.modal.size.*` change to the new identifier.)

`ModalTerminalPane.swift`: `git mv Sources/Flock/Rt/RtModalPane.swift Sources/Flock/Views/Modal/ModalTerminalPane.swift`, rename the type, and reword its doc comment to be about any hosted pane:

```swift
/// One pane on its ghostty surface inside a modal. It attaches and parks
/// like a canvas cell, through the view model's per-pane chain.
///
/// Given a `command`, the pane loader covers the pane while that command is
/// on its way up (`RtModalLoaderPolicy`). The surface stays mounted
/// underneath at zero opacity: libghostty needs a real window to render into.
```

`ChromeModal.swift`:

```swift
import FlockCore
import SwiftUI

/// A modal over the area it is mounted on: a backdrop that dims it and
/// dismisses on a click, and centred on it a card sized by `ModalSize`,
/// holding a title row (the caller's leading content, the size control and
/// a close control), the caller's content, and an optional footer.
struct ChromeModal<Leading: View, Content: View, Footer: View>: View {
    let theme: Theme
    let size: ModalSize
    var footerHeight: CGFloat = 0
    let onSize: (ModalSize) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: (_ area: CGSize, _ scale: CGFloat) -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(\.displayScale) private var displayScale

    private typealias Metrics = ChromeMetrics.Modal

    var body: some View {
        GeometryReader { proxy in
            let scale = displayScale > 0 ? displayScale : 2
            let frame = Self.boxFrame(
                in: proxy.size, origin: proxy.frame(in: .global).origin, scale: scale,
                fraction: Metrics.sizeFraction(size)
            )
            ZStack(alignment: .topLeading) {
                backdrop
                card(size: frame.size, scale: scale)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    /// Both edges of each axis are snapped where they land in the window, as
    /// `CanvasGrid` snaps a pane box: the pane inside sits a whole number of
    /// points in from them, so ghostty composites it on whole device pixels.
    static func boxFrame(in area: CGSize, origin: CGPoint, scale: CGFloat, fraction: CGFloat) -> CGRect {
        <body of RtModalView.boxFrame, verbatim>
    }

    private var backdrop: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? Metrics.lightBackdropOpacity : Metrics.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
    }

    private func card(size boxSize: CGSize, scale: CGFloat) -> some View {
        let area = CGSize(
            width: max(0, boxSize.width - 2 * Metrics.paneInset),
            height: max(0, boxSize.height - Metrics.TitleRow.height - footerHeight - 2 * Metrics.paneInset)
        )
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        return VStack(spacing: 0) {
            ModalTitleRow(theme: theme, size: size, onSize: onSize, onClose: onDismiss, leading: leading)
            content(area, scale)
                .frame(width: area.width, height: area.height)
                .padding(Metrics.paneInset)
            footer()
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .top)
        .background(theme.pane)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.paneBorder, lineWidth: ChromeMetrics.ruleWidth))
        // Cast by a shape behind the card rather than by the card itself,
        // which would pull the terminal's surface through an offscreen pass.
        .background {
            shape
                .fill(theme.pane)
                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        }
    }
}

extension ChromeModal where Footer == EmptyView {
    init(
        theme: Theme, size: ModalSize, onSize: @escaping (ModalSize) -> Void, onDismiss: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder content: @escaping (_ area: CGSize, _ scale: CGFloat) -> Content
    ) {
        self.init(
            theme: theme, size: size, onSize: onSize, onDismiss: onDismiss,
            leading: leading, content: content, footer: { EmptyView() }
        )
    }
}

/// The caller's leading content, then the size control and the close
/// control at the trailing edge.
struct ModalTitleRow<Leading: View>: View {
    let theme: Theme
    let size: ModalSize
    let onSize: (ModalSize) -> Void
    let onClose: () -> Void
    @ViewBuilder let leading: () -> Leading

    private typealias Metrics = ChromeMetrics.Modal.TitleRow

    var body: some View {
        HStack(spacing: Metrics.gap) {
            leading()
            Spacer(minLength: 0)
            HStack(spacing: ChromeMetrics.Modal.SizeControl.gapBeforeClose) {
                ModalSizeControl(theme: theme, selected: size, onSelect: onSize)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(ChromeType.modalClose)
                        .foregroundStyle(theme.textDim)
                        .frame(width: Metrics.closeGlyphSize, height: Metrics.closeGlyphSize)
                        .hoverWash(theme, cornerRadius: Metrics.buttonCornerRadius)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("flock.modal.close")
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.height)
        .background(theme.chrome)
    }
}
```

The memberwise init with three trailing closures needs the explicit `init` SwiftUI views get when their closures are `@ViewBuilder let`; if the compiler refuses the synthesized one, write it out the same way as the `EmptyView` extension.

- [ ] **Step 5: Rebuild the rt modal on it**

`RtModalView.body` keeps its guard and becomes:

```swift
        if viewModel.rtModalIsOver(solo: solo), let modal = viewModel.rt.modal, let item = viewModel.rt.modalItem {
            let paneID = shownPaneID(modal: modal, item: item)
            let fontSize = textSizeStore.points(for: item.kind)
            ChromeModal(
                theme: theme, size: modalSizeStore.size(for: item.kind),
                footerHeight: item.strip == nil ? 0 : ChromeMetrics.RtModal.Strip.height,
                onSize: { modalSizeStore.select($0, for: item.kind) }, onDismiss: close
            ) {
                RtModalTitle(
                    theme: theme, title: item.modalTitle(home: NSHomeDirectory()),
                    showsBackToRunner: modal.serviceTabID != nil, onBack: back
                )
            } content: { area, scale in
                let fit = SurfaceGrid.fit(inner: area, cell: TerminalCellMetrics.cell(fontSize: fontSize, scale: scale))
                // A service is never typed into: only the item's own pane waits
                // for its command.
                ModalTerminalPane(
                    theme: theme, viewModel: viewModel, paneID: paneID, grid: PTYSize(cols: fit.cols, rows: fit.rows),
                    surfaceSize: fit.size, fontSizePoints: fontSize, isFocused: item.strip == nil,
                    command: modal.serviceTabID != nil ? nil : ModalTerminalPane.Command(
                        started: item.started, startedAt: item.startedAt, ended: item.strip != nil || !item.isRunning
                    ),
                    onFocus: {}
                )
                // A service shown in place of its board is another pane: it gets
                // a view of its own, so the board's surface parks as it leaves.
                .id(paneID)
            } footer: {
                if let strip = item.strip { RtModalStripView(theme: theme, strip: strip) }
            }
            // The sidebar stays live under the modal, so a rename editor can be
            // open there, and the keys typed into it are not the strip's; nor
            // are the palette's, which can open over the modal.
            .background(RtModalKeyMonitor(
                stripShown: item.strip != nil && !viewModel.renameEditorIsOnScreen && !commandPalette.isOpen, onClose: close
            ))
        }
```

`RtModalTitleRow` becomes `RtModalTitle`: only the back button, its divider and the title text (the old row's leading part, verbatim, reading `ChromeMetrics.Modal.TitleRow` for shared values and `ChromeMetrics.RtModal` for the back pieces). Delete `RtModalView.boxFrame`, `backdrop`, `box`, and `RtModalSizeControl`. Update any caller of `RtModalView.boxFrame` to `ChromeModal.boxFrame`.

- [ ] **Step 6: Same tests, same pixels**

```bash
xcodegen
xcodebuild test -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockCoreTests/RtModalSizeTests
TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=/tmp/flock-modal/after xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockChromeRender/RtModalChromeRenderTests
for f in /tmp/flock-modal/before/*.png; do cmp -s "$f" "/tmp/flock-modal/after/$(basename "$f")" && echo "same $(basename "$f")" || echo "DIFFERS $(basename "$f")"; done
```

Expected: PASS, and every PNG `same`. A difference means the extraction changed layout: open both and fix it before going on.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
Scripts/checks.sh
git commit -m "extract the shared modal (ChromeModal, ModalSize, ModalTerminalPane) from the rt modal"
```

---

### Task 2: Pin placement in the store

**Files:**
- Modify: `Sources/FlockCore/Rail/PinnedWorkspaces.swift`
- Test: `Tests/FlockCoreTests/PinnedWorkspaceStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum PinPlacement: String, Codable, Sendable { case rail, topBar }`
  - `PinnedWorkspace.placement: PinPlacement` (decodes missing as `.rail`)
  - `PinnedWorkspaceStore.pins(in: PinPlacement) -> [PinnedWorkspace]`
  - `PinnedWorkspaceStore.add(workspace:name:folder:at:placement:) -> PinnedWorkspace?` (`placement` defaults to `.rail`; `at` counts pins of that placement)
  - `PinnedWorkspaceStore.move(_:toInsertIndex:)` (index counts the pin's own placement, as drawn)
  - `PinnedWorkspaceStore.setPlacement(_ id: PinID, to: PinPlacement, at: Int?)` (`nil` appends)

- [ ] **Step 1: Write the failing tests**

Append to `PinnedWorkspaceStoreTests`:

```swift
    func testAStoredPinWithoutAPlacementDecodesAsRail() throws {
        let json = #"{"version":1,"pins":[{"id":{"rawValue":"p1"},"name":"acme","folder":"/acme","confirmed":true}]}"#
        let defaults = defaults()
        defaults.set(Data(json.utf8), forKey: PinnedWorkspaceStore.defaultsKey)
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        XCTAssertEqual(store.pins.map(\.placement), [.rail])
    }

    func testPlacementRoundTripsThroughDefaults() {
        let defaults = defaults()
        let store = PinnedWorkspaceStore(userDefaults: defaults)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        store.setPlacement(a.id, to: .topBar, at: nil)
        XCTAssertEqual(PinnedWorkspaceStore(userDefaults: defaults).pins.map(\.placement), [.topBar])
    }

    /// The rail draws only rail pins, so its drop index must not count a
    /// top-bar pin that sits between them in the stored order.
    func testIndicesCountOnlyThePlacementBeingDrawn() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        let a = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "a", folder: "/a", at: nil)!
        let t = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "t", folder: "/t", at: nil, placement: .topBar)!
        let b = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "b", folder: "/b", at: nil)!
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["a", "b"])
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["t"])
        store.move(b.id, toInsertIndex: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["b", "a"])
        store.move(b.id, toInsertIndex: 2)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["a", "b"])
        store.setPlacement(a.id, to: .topBar, at: 0)
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["a", "t"])
        store.setPlacement(t.id, to: .rail, at: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["t", "b"])
        XCTAssertEqual(store.pins(in: .topBar).map(\.name), ["a"])
    }

    func testAddAtAnIndexCountsItsOwnPlacement() {
        let store = PinnedWorkspaceStore(userDefaults: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w1"), name: "t", folder: "/t", at: nil, placement: .topBar)
        _ = store.add(workspace: WorkspaceID(rawValue: "w2"), name: "a", folder: "/a", at: nil)
        _ = store.add(workspace: WorkspaceID(rawValue: "w3"), name: "b", folder: "/b", at: 0)
        XCTAssertEqual(store.pins(in: .rail).map(\.name), ["b", "a"])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run `PinnedWorkspaceStoreTests`. Expected: compile failure (`placement`, `pins(in:)`, `setPlacement` undefined).

- [ ] **Step 3: Implement**

In `PinnedWorkspaces.swift`, above `PinnedWorkspace`:

```swift
/// Where a pin is drawn: in the rail's PINNED, or as a title-bar icon whose
/// workspace no other list shows.
public enum PinPlacement: String, Codable, Sendable {
    case rail
    case topBar
}
```

In `PinnedWorkspace` add the field and a decoder (synthesized `Decodable` would require the key, and pins stored by older builds have none):

```swift
    public var placement: PinPlacement = .rail

    enum CodingKeys: String, CodingKey {
        case id, name, folder, workspace, syncedLabel, confirmed, placement
    }

    public init(
        id: PinID, name: String, folder: String, workspace: WorkspaceID?, syncedLabel: String?, confirmed: Bool,
        placement: PinPlacement = .rail
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.workspace = workspace
        self.syncedLabel = syncedLabel
        self.confirmed = confirmed
        self.placement = placement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PinID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folder = try container.decode(String.self, forKey: .folder)
        workspace = try container.decodeIfPresent(WorkspaceID.self, forKey: .workspace)
        syncedLabel = try container.decodeIfPresent(String.self, forKey: .syncedLabel)
        confirmed = try container.decode(Bool.self, forKey: .confirmed)
        placement = try container.decodeIfPresent(PinPlacement.self, forKey: .placement) ?? .rail
    }
```

In `PinnedWorkspaceStore`, replace `add` and `move`, and add `pins(in:)`, `setPlacement` and `place`:

```swift
    public func pins(in placement: PinPlacement) -> [PinnedWorkspace] {
        pins.filter { $0.placement == placement }
    }

    @discardableResult
    public func add(
        workspace: WorkspaceID, name: String, folder: String, at index: Int?, placement: PinPlacement = .rail
    ) -> PinnedWorkspace? {
        guard pin(linkedTo: workspace) == nil, !isNameTaken(name, except: nil) else { return nil }
        let pin = PinnedWorkspace(
            id: .make(), name: name, folder: folder, workspace: workspace, syncedLabel: name, confirmed: true,
            placement: placement
        )
        pins.append(pin)
        if let index { place(pin.id, in: placement, at: index, saving: false) }
        save()
        return self.pin(pin.id)
    }

    /// `index` counts the pins of this one's placement as drawn, the moving
    /// one included.
    public func move(_ id: PinID, toInsertIndex index: Int) {
        guard let pin = pin(id) else { return }
        place(id, in: pin.placement, at: index)
    }

    /// `index` counts the destination's pins as drawn; nil puts it last.
    public func setPlacement(_ id: PinID, to placement: PinPlacement, at index: Int?) {
        place(id, in: placement, at: index)
    }

    private func place(_ id: PinID, in placement: PinPlacement, at index: Int?, saving: Bool = true) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        let ownSlot = pins[from].placement == placement
            ? pins.indices.filter { pins[$0].placement == placement }.firstIndex(of: from)
            : nil
        var next = pins
        var moving = next.remove(at: from)
        moving.placement = placement
        let peers = next.indices.filter { next[$0].placement == placement }
        var target = index ?? peers.count
        if let ownSlot, target > ownSlot { target -= 1 }
        target = min(max(target, 0), peers.count)
        let position = target < peers.count ? peers[target] : (peers.last.map { $0 + 1 } ?? next.count)
        next.insert(moving, at: position)
        guard next != pins else { return }
        pins = next
        if saving { save() }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run `PinnedWorkspaceStoreTests` (all of it: the existing add/move tests must stay green). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Rail/PinnedWorkspaces.swift Tests/FlockCoreTests/PinnedWorkspaceStoreTests.swift
git commit -m "pins: placement (rail or top bar), indices per placement"
```

---

### Task 3: Hiding top-bar workspaces from the session and the rail

**Files:**
- Modify: `Sources/FlockCore/Rt/VisibleSession.swift`
- Modify: `Sources/FlockCore/Rail/RailSections.swift`
- Modify: `Sources/FlockCore/Theme/WorkspaceIdentityStore.swift:44-50`
- Test: `Tests/FlockCoreTests/VisibleSessionTests.swift`, `Tests/FlockCoreTests/RailSectionsTests.swift`, `Tests/FlockCoreTests/WorkspaceIdentityStoreTests.swift`

**Interfaces:**
- Consumes: `PinPlacement`, `PinnedWorkspace.placement` (Task 2)
- Produces:
  - `SessionModel.hiding(_ hidden: Set<WorkspaceID>) -> SessionModel`
  - `RailSections.topBar: [RailSections.PinnedRow]` (top-bar pins, `record` from the model given)
  - `RailSections.init(model:board:herdProgress:pins:topBarModel:)`: `topBarModel` (default `nil`, meaning `model`) is where top-bar rows find their records

- [ ] **Step 1: Write the failing tests**

`VisibleSessionTests` (reuses its `model(...)` fixture):

```swift
    func testHidingDropsTheNamedWorkspaceAndClearsFocusInsideIt() {
        let visible = model(focusedWorkspace: "w1", focusedTab: "w1:t1", focusedPane: "w1:p1")
            .hiding([WorkspaceID(rawValue: "w1")])
        XCTAssertFalse(visible.workspaces.contains { $0.workspaceID == WorkspaceID(rawValue: "w1") })
        XCTAssertNil(visible.tabs[WorkspaceID(rawValue: "w1")])
        XCTAssertNil(visible.panes[PaneID(rawValue: "w1:p1")])
        XCTAssertNil(visible.focusedWorkspaceID)
        XCTAssertNil(visible.focusedTabID)
        XCTAssertNil(visible.focusedPaneID)
    }
```

`RailSectionsTests` (use the file's existing model fixture builder; if it has none, copy `model(_:)` from `PinnedWorkspaceStoreTests`):

```swift
    func testTopBarPinsLeavePinnedAndFindTheirRecordInTheTopBarModel() {
        let full = model([("w1", "acme"), ("w2", "dash")])
        let hidden = full.hiding([WorkspaceID(rawValue: "w2")])
        let rail = PinnedWorkspace(id: PinID(rawValue: "p1"), name: "acme", folder: "/acme",
                                   workspace: WorkspaceID(rawValue: "w1"), syncedLabel: "acme", confirmed: true)
        let bar = PinnedWorkspace(id: PinID(rawValue: "p2"), name: "dash", folder: "/dash",
                                  workspace: WorkspaceID(rawValue: "w2"), syncedLabel: "dash", confirmed: true,
                                  placement: .topBar)
        let sections = RailSections(model: hidden, board: nil, pins: [rail, bar], topBarModel: full)
        XCTAssertEqual(sections.pinned.map(\.pin.id), [rail.id])
        XCTAssertEqual(sections.topBar.map(\.pin.id), [bar.id])
        XCTAssertEqual(sections.topBar.first?.record?.label, "dash")
    }
```

`WorkspaceIdentityStoreTests`:

```swift
    func testATopBarPinKeepsItsSymbolThroughARefresh() {
        let suite = "flock-identity-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: suite)!)
        let bar = PinnedWorkspace(id: PinID(rawValue: "p2"), name: "dash", folder: "/dash", workspace: nil,
                                  syncedLabel: nil, confirmed: false, placement: .topBar)
        store.setOverride("key.fill", for: bar.identityKey)
        let empty = SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [], tabs: [], panes: [], layouts: []
        ))
        store.refresh(RailSections(model: empty, board: nil, pins: [bar]))
        XCTAssertEqual(store.symbol(for: bar.identityKey), "key.fill")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run the three classes. Expected: compile failure (`hiding`, `topBar`, `topBarModel`).

- [ ] **Step 3: Implement**

`VisibleSession.swift`: generalise the filter; `withoutFlockOwned` becomes a call to it.

```swift
extension SessionModel {
    /// The session without flock's own workspaces, which is the model every
    /// view reads. Focus that sits inside one reads as none, so nothing that
    /// follows herdr's focus can follow it there.
    public var withoutFlockOwned: SessionModel {
        hiding(Set(workspaces.filter { RtLabels.isFlockOwned(workspaceLabel: $0.label) }.map(\.workspaceID)))
    }

    public func hiding(_ hidden: Set<WorkspaceID>) -> SessionModel {
        guard !hidden.isEmpty else { return self }
        var visible = self
        let hiddenTabs = Set(hidden.flatMap { tabs[$0] ?? [] }.map(\.tabID))
        visible.workspaces.removeAll { hidden.contains($0.workspaceID) }
        for workspace in hidden { visible.tabs.removeValue(forKey: workspace) }
        visible.panes = panes.filter { !hidden.contains($0.value.workspaceID) }
        visible.layouts = layouts.filter { !hidden.contains($0.value.workspaceID) }
        if let workspace = focusedWorkspaceID, hidden.contains(workspace) {
            visible.focusedWorkspaceID = nil
        }
        if let tab = focusedTabID, hiddenTabs.contains(tab) {
            visible.focusedTabID = nil
        }
        if let pane = focusedPaneID, let record = panes[pane], hidden.contains(record.workspaceID) {
            visible.focusedPaneID = nil
        }
        return visible
    }
}
```

`RailSections.swift`: add the property and split pins by placement.

```swift
    public let pinned: [PinnedRow]
    /// Drawn in the title bar, never in the rail.
    public let topBar: [PinnedRow]
```

In `init`, add `topBarModel: SessionModel? = nil` as the last parameter, and replace the `pinned = ...` line with:

```swift
        pinned = pins.filter { $0.placement == .rail }.map { PinnedRow(pin: $0, record: $0.workspace.flatMap { records[$0] }) }
        var barRecords: [WorkspaceID: WorkspaceRecord] = [:]
        for record in (topBarModel ?? model).workspaces where barRecords[record.workspaceID] == nil {
            barRecords[record.workspaceID] = record
        }
        topBar = pins.filter { $0.placement == .topBar }.map { PinnedRow(pin: $0, record: $0.workspace.flatMap { barRecords[$0] }) }
```

`WorkspaceIdentityStore.keys(in:)`: count top-bar pins as pins.

```swift
        let pins = (sections.pinned + sections.topBar).map(\.pin.identityKey)
```

- [ ] **Step 4: Run to verify they pass**

Run `VisibleSessionTests`, `RailSectionsTests`, `WorkspaceIdentityStoreTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Rt/VisibleSession.swift Sources/FlockCore/Rail/RailSections.swift Sources/FlockCore/Theme/WorkspaceIdentityStore.swift Tests/FlockCoreTests/VisibleSessionTests.swift Tests/FlockCoreTests/RailSectionsTests.swift Tests/FlockCoreTests/WorkspaceIdentityStoreTests.swift
git commit -m "hide top-bar workspaces through the session filter; rail sections split pins"
```

---

### Task 4: View model: placement, the one-tab rule, opening, rename and unpin

**Files:**
- Create: `Sources/FlockCore/Rail/TopBarOverlayStore.swift`
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`update` at ~259, `railSections` ~1798, pin API ~1802-1840, `create` ~1935, `reopen` ~1956, `isOpen` ~1975, `shownStatus(of workspace:)` ~952)
- Test: `Tests/FlockCoreTests/SessionViewModelTopBarTests.swift` (new)

**Interfaces:**
- Consumes: Tasks 2-3.
- Produces:
  - `TopBarOverlayStore` (`@MainActor @Observable`): `openPin: PinID?`, `open(_:)`, `close()`
  - `SessionViewModel.userModel: SessionModel?` (full model minus flock-owned only)
  - `SessionViewModel.topBarOverlay: TopBarOverlayStore`
  - `SessionViewModel.moveToTopBar(workspace: WorkspaceID, at: Int?)`
  - `SessionViewModel.moveToTopBar(pin: PinID, at: Int?)`
  - `SessionViewModel.moveToSidebar(pin: PinID, at: Int?)`
  - `SessionViewModel.toggleTopBar(_ id: PinID) async`
  - `SessionViewModel.renameTopBarPin(_ id: PinID, to: String) async`
  - `SessionViewModel.unpinTopBar(_ id: PinID)`
  - `SessionViewModel.topBarStatus(of pin: PinnedWorkspace) -> ShownStatus?` (nil while empty)
  - `SessionViewModel.reopen(_ id: PinID, focus: Bool = true) async`
  - `static SessionViewModel.topBarTabLimitNotice(name: String, tabs: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlockCoreTests/SessionViewModelTopBarTests.swift`. The fixture builds `tabs` per workspace so the one-tab rule can be exercised; `CreatingClient` answers `workspace.create` like herdr does.

```swift
import XCTest
@testable import FlockCore

private actor CreatingClient: HerdrCommandClient {
    private(set) var calls: [(String, [String: JSONValue])] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        calls.append((method, params))
        guard method == "workspace.create" else { return Data("{}".utf8) }
        return Data(#"{"workspace":{"workspace_id":"wN"},"tab":{"tab_id":"wN:t1","workspace_id":"wN"},"root_pane":{"pane_id":"wN:p1"}}"#.utf8)
    }
}

@MainActor
final class SessionViewModelTopBarTests: XCTestCase {
    /// `tabs` per workspace id; one when absent.
    private func model(_ workspaces: [(id: String, label: String)], tabs: [String: Int] = [:], focused: String? = nil) -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: focused.map { WorkspaceID(rawValue: $0) },
            focusedTabID: focused.map { TabID(rawValue: "\($0):t1") }, focusedPaneID: nil,
            workspaces: workspaces.enumerated().map { index, item in
                WorkspaceRecord(workspaceID: WorkspaceID(rawValue: item.id), label: item.label, number: index + 1,
                                activeTabID: TabID(rawValue: "\(item.id):t1"), agentStatus: .idle)
            },
            tabs: workspaces.flatMap { item in
                (1...(tabs[item.id] ?? 1)).map { n in
                    TabRecord(tabID: TabID(rawValue: "\(item.id):t\(n)"), workspaceID: WorkspaceID(rawValue: item.id),
                              label: "zsh", number: n, paneCount: 1, agentStatus: .idle)
                }
            },
            panes: workspaces.map {
                PaneRecord(paneID: PaneID(rawValue: "\($0.id):p1"), workspaceID: WorkspaceID(rawValue: $0.id),
                           tabID: TabID(rawValue: "\($0.id):t1"), focused: false, agentStatus: .idle, revision: 0,
                           terminalTitleStripped: nil, label: nil, cwd: "/acme/\($0.label)", scroll: nil)
            },
            layouts: []
        ))
    }

    private func viewModel(client: any HerdrCommandClient = CreatingClient(), notices: @escaping @MainActor (String) -> Void = { _ in }) -> SessionViewModel {
        let suite = "flock-topbar-vm-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: UserDefaults(suiteName: suite)!)
        return SessionViewModel(client: client, planExecutor: nil, noticeSink: notices, identity: identity)
    }

    private let w1 = WorkspaceID(rawValue: "w1")
    private let w2 = WorkspaceID(rawValue: "w2")

    func testMovingAOneTabWorkspaceHidesItEverywhereButKeepsItLinked() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertEqual(vm.model?.workspaces.map(\.workspaceID), [w1])
        XCTAssertEqual(vm.userModel?.workspaces.map(\.workspaceID), [w1, w2])
        let pin = vm.pins.pins(in: .topBar)[0]
        XCTAssertEqual(pin.workspace, w2)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        XCTAssertEqual(vm.pins.pin(pin.id)?.workspace, w2, "a reconcile must not empty a top-bar pin")
        XCTAssertTrue(vm.isOpen(pin))
        XCTAssertEqual(vm.railSections(board: nil)?.topBar.first?.record?.workspaceID, w2)
    }

    func testAWorkspaceWithTwoTabsIsRefusedWithTheNotice() {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], tabs: ["w2": 2]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertTrue(vm.pins.pins.isEmpty)
        XCTAssertEqual(notices, [SessionViewModel.topBarTabLimitNotice(name: "dash", tabs: 2)])
        XCTAssertTrue(notices[0].contains("one tab"))
    }

    func testARailPinWithTwoTabsIsRefusedAndStaysInTheRail() {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w2", "dash")], tabs: ["w2": 3]), connection: .live)
        vm.pin(workspace: w2)
        let pin = vm.pins.pins[0]
        vm.moveToTopBar(pin: pin.id, at: nil)
        XCTAssertEqual(vm.pins.pin(pin.id)?.placement, .rail)
        XCTAssertEqual(notices.count, 1)
    }

    func testAnEmptyPinMayMoveToTheTopBar() {
        let vm = viewModel()
        vm.update(model: model([("w2", "dash")]), connection: .live)
        vm.pin(workspace: w2)
        vm.update(model: model([]), connection: .live)
        let pin = vm.pins.pins[0]
        vm.moveToTopBar(pin: pin.id, at: nil)
        XCTAssertEqual(vm.pins.pin(pin.id)?.placement, .topBar)
    }

    func testMovingTheSelectedWorkspaceLandsTheSelectionOnANeighbour() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w2"), connection: .live)
        XCTAssertEqual(vm.selectedWorkspaceID, w2)
        vm.moveToTopBar(workspace: w2, at: nil)
        XCTAssertEqual(vm.selectedWorkspaceID, w1)
    }

    func testMovingBackToTheSidebarShowsItAgain() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.moveToSidebar(pin: vm.pins.pins[0].id, at: 0)
        XCTAssertEqual(vm.model?.workspaces.map(\.workspaceID), [w1, w2])
        XCTAssertEqual(vm.railSections(board: nil)?.pinned.map(\.pin.name), ["dash"])
    }

    func testOpeningAnEmptyTopBarPinCreatesWithoutFocusOrSelection() async {
        let client = CreatingClient()
        let vm = viewModel(client: client)
        vm.update(model: model([("w1", "acme"), ("w2", "dash")], focused: "w1"), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.update(model: model([("w1", "acme")], focused: "w1"), connection: .live)
        let pin = vm.pins.pins(in: .topBar)[0]
        XCTAssertNil(pin.workspace)
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(vm.topBarOverlay.openPin, pin.id)
        XCTAssertEqual(vm.selectedWorkspaceID, w1)
        let create = await client.calls.first { $0.0 == "workspace.create" }
        XCTAssertEqual(create?.1["focus"], .bool(false))
        XCTAssertEqual(vm.pins.pin(pin.id)?.workspace, WorkspaceID(rawValue: "wN"))
    }

    func testTogglingTheOpenPinClosesAndAnEmptiedPinClosesTheOverlay() async {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        let pin = vm.pins.pins(in: .topBar)[0]
        await vm.toggleTopBar(pin.id)
        XCTAssertEqual(vm.topBarOverlay.openPin, pin.id)
        await vm.toggleTopBar(pin.id)
        XCTAssertNil(vm.topBarOverlay.openPin)
        await vm.toggleTopBar(pin.id)
        vm.update(model: model([("w1", "acme")]), connection: .live)
        XCTAssertNil(vm.topBarOverlay.openPin)
    }

    func testUnpinningAnOpenTopBarPinPutsTheWorkspaceBackInTheRail() {
        let vm = viewModel()
        vm.update(model: model([("w1", "acme"), ("w2", "dash")]), connection: .live)
        vm.moveToTopBar(workspace: w2, at: nil)
        vm.unpinTopBar(vm.pins.pins[0].id)
        XCTAssertTrue(vm.pins.pins.isEmpty)
        XCTAssertEqual(vm.railSections(board: nil)?.workspaces.map(\.workspaceID), [w1, w2])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run `SessionViewModelTopBarTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

Create `Sources/FlockCore/Rail/TopBarOverlayStore.swift`:

```swift
import Foundation
import Observation

/// Which top-bar workspace the overlay shows; one at a time.
@MainActor
@Observable
public final class TopBarOverlayStore {
    public private(set) var openPin: PinID?

    public init() {}

    public func open(_ id: PinID) { openPin = id }

    public func close() { openPin = nil }
}
```

In `SessionViewModel`:

1. Properties beside `fullModel`:

```swift
    /// The session without flock's own workspaces but with the top bar's,
    /// which pins are reconciled against: the filtered `model` would read a
    /// top-bar pin's workspace as closed.
    public private(set) var userModel: SessionModel?
    public let topBarOverlay = TopBarOverlayStore()
```

2. In `update(model:connection:)`, replace the first two lines and remove the `pins.reconcile` block at the end:

```swift
        fullModel = newFullModel
        let user = newFullModel?.withoutFlockOwned
        userModel = user
        if connection == .live, let user {
            pins.reconcile(with: user, reopening: reopening) { RailSections.isRailRow(label: $0.label, board: nil) }
        }
        let model = user?.hiding(topBarWorkspaces)
```

and at the end of `update`, after `rt.update(model: fullModel)` and the live block (which keeps its `keepOnly` lines):

```swift
        closeTopBarOverlayIfGone()
```

3. Helpers and API near the pin methods:

```swift
    private var topBarWorkspaces: Set<WorkspaceID> {
        Set(pins.pins(in: .topBar).compactMap(\.workspace))
    }

    /// Re-filters after a placement change, through the same path a herdr
    /// update takes, so the selection leaves a workspace that has just
    /// moved to the top bar.
    private func refreshVisibility() {
        update(model: fullModel, connection: connectionState)
    }

    private func closeTopBarOverlayIfGone() {
        guard let id = topBarOverlay.openPin else { return }
        guard let pin = pins.pin(id), pin.placement == .topBar else { return topBarOverlay.close() }
        if pin.workspace == nil, !reopening.contains(id) { topBarOverlay.close() }
    }

    public nonisolated static func topBarTabLimitNotice(name: String, tabs: Int) -> String {
        "Top-bar workspaces show a single view, so they hold one tab. \"\(name)\" has \(tabs) tabs: close the extras, then move it."
    }

    /// nil, after posting the notice, when `workspace` has more than one tab.
    private func passesTopBarTabLimit(_ workspace: WorkspaceID?, name: String) -> Bool {
        guard let workspace, let count = userModel?.tabs[workspace]?.count, count > 1 else { return true }
        noticeSink(Self.topBarTabLimitNotice(name: name, tabs: count))
        return false
    }

    public func moveToTopBar(workspace: WorkspaceID, at index: Int?) {
        if let existing = pins.pin(linkedTo: workspace) { return moveToTopBar(pin: existing.id, at: index) }
        guard let record = model?.workspaces.first(where: { $0.workspaceID == workspace }),
              passesTopBarTabLimit(workspace, name: record.label) else { return }
        pin(workspace: workspace)
        guard let pin = pins.pin(linkedTo: workspace) else { return }
        pins.setPlacement(pin.id, to: .topBar, at: index)
        refreshVisibility()
    }

    public func moveToTopBar(pin id: PinID, at index: Int?) {
        guard let pin = pins.pin(id), passesTopBarTabLimit(pin.workspace, name: pin.name) else { return }
        pins.setPlacement(id, to: .topBar, at: index)
        refreshVisibility()
    }

    public func moveToSidebar(pin id: PinID, at index: Int?) {
        guard pins.pin(id) != nil else { return }
        if topBarOverlay.openPin == id { topBarOverlay.close() }
        pins.setPlacement(id, to: .rail, at: index)
        refreshVisibility()
    }

    public func toggleTopBar(_ id: PinID) async {
        guard let pin = pins.pin(id), pin.placement == .topBar else { return }
        if topBarOverlay.openPin == id { return topBarOverlay.close() }
        topBarOverlay.open(id)
        if !isOpen(pin) {
            await reopen(id, focus: false)
            closeTopBarOverlayIfGone()
        }
    }

    /// The bar has no inline editor of its own: an open workspace is renamed
    /// in herdr, and the pin follows its label on the next reconcile.
    public func renameTopBarPin(_ id: PinID, to text: String) async {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let pin = pins.pin(id) else { return }
        guard isOpen(pin), let workspace = pin.workspace else { return renamePin(id, to: name) }
        guard !pins.isNameTaken(name, except: id) else {
            noticeSink("A pinned workspace is already called \"\(name)\".")
            return
        }
        await run(OpPlan(ops: [.renameWorkspace(workspace, name)], label: "Rename workspace"))
    }

    public func unpinTopBar(_ id: PinID) {
        guard let pin = pins.pin(id) else { return }
        if topBarOverlay.openPin == id { topBarOverlay.close() }
        if isOpen(pin) { unpin(id) } else { removePin(id) }
        refreshVisibility()
    }

    public func topBarStatus(of pin: PinnedWorkspace) -> ShownStatus? {
        guard let workspace = pin.workspace,
              let record = userModel?.workspaces.first(where: { $0.workspaceID == workspace }) else { return nil }
        guard !backgroundWork.isEmpty else { return ShownStatus(record.agentStatus) }
        return ShownStatus.aggregate(
            herdr: record.agentStatus,
            panes: userModel?.panes.values.filter { $0.workspaceID == workspace } ?? [],
            backgroundWork: backgroundWork
        )
    }
```

4. `railSections(board:herdProgress:)` passes the top-bar model:

```swift
        model.map { RailSections(model: $0, board: board, herdProgress: herdProgress, pins: pins.pins, topBarModel: userModel) }
```

5. `isOpen` reads `userModel`:

```swift
        return userModel?.workspaces.contains { $0.workspaceID == workspace } ?? false
```

6. `create` gains `lands: Bool = true`; the three selection lines run only when it is true:

```swift
    private func create(_ method: String, _ params: [String: JSONValue], label: String, lands: Bool = true) async -> CreatedTab? {
        do {
            let data = try await client.requestRaw(method, params)
            guard let created = Self.extractCreatedTab(data) else { return nil }
            if lands {
                selectedWorkspaceID = created.workspaceID
                selectedTabID = created.tabID
                landIn(pane: created.rootPaneID)
            }
            return created
```

7. `reopen(_:focus:)`: add the parameter, send it, and pass `lands: focus`:

```swift
    public func reopen(_ id: PinID, focus: Bool = true) async {
        ...
        let params: [String: JSONValue] = [
            "focus": .bool(focus), "cwd": .string(folderIsThere ? pin.folder : homeDirectory),
        ]
        guard let created = await create("workspace.create", params, label: "Reopen \(pin.name)", lands: focus) else { return }
        ...
```

If the hiding filter's previous-model diff in `reconcileAttentionToasts(previous:)` raises a toast when a workspace moves to the top bar, guard it there by comparing against `topBarWorkspaces`; the test suite in Step 4 says whether it does.

- [ ] **Step 4: Run to verify they pass**

Run `SessionViewModelTopBarTests`, `SessionViewModelPinTests`, `VisibleSessionTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
xcodegen
git add Sources/FlockCore/Rail/TopBarOverlayStore.swift Sources/FlockCore/ViewModels/SessionViewModel.swift Tests/FlockCoreTests/SessionViewModelTopBarTests.swift
Scripts/checks.sh
git commit -m "view model: top-bar placement, one-tab rule, overlay open and close"
```

---

### Task 5: Menus

**Files:**
- Modify: `Sources/FlockCore/Menus/ChromeMenuModel.swift`
- Modify: `Sources/Flock/Views/WorkspaceMark.swift` (`WorkspaceMenu`, `EmptyPinMenu`)
- Test: `Tests/FlockCoreTests/ChromeMenuModelTests.swift`

**Interfaces:**
- Consumes: Task 4's view model API.
- Produces:
  - `WorkspaceMenuAction.moveToTopBar`, `EmptyPinMenuAction.moveToTopBar`
  - `public enum TopBarMenuAction { case moveToSidebar, rename, changeSymbol, unpin }`
  - `TopBarMenuModel.entries() -> [ChromeMenuEntry<TopBarMenuAction>]`

- [ ] **Step 1: Write the failing tests**

```swift
    func testRailRowsOfferMoveToTopBar() {
        let model = <the file's existing one-workspace fixture, workspace "w1">
        XCTAssertEqual(WorkspaceMenuModel.entries(for: WorkspaceID(rawValue: "w1"), model: model).map(\.action),
                       [.rename, .pin, .moveToTopBar, .close])
        XCTAssertEqual(WorkspaceMenuModel.entries(for: WorkspaceID(rawValue: "w1"), model: model, isPinned: true).map(\.action),
                       [.rename, .changeFolder, .moveToTopBar, .unpin])
        XCTAssertEqual(EmptyPinMenuModel.entries().map(\.action), [.rename, .changeFolder, .moveToTopBar, .remove])
    }

    func testTopBarCellsOfferTheFourActionsInOrder() {
        let entries = TopBarMenuModel.entries()
        XCTAssertEqual(entries.map(\.label), ["Move to Sidebar", "Rename", "Change Icon\u{2026}", "Unpin"])
        XCTAssertEqual(entries.map(\.accessibilityIdentifier), [
            "flock.topBar.menu.moveToSidebar", "flock.topBar.menu.rename",
            "flock.topBar.menu.changeSymbol", "flock.topBar.menu.unpin",
        ])
    }
```

Replace the placeholder fixture line with whatever `ChromeMenuModelTests` already uses to build a model holding `w1` (read the file's top first). Update any existing assertions on these entry lists to the new orders.

- [ ] **Step 2: Run to verify they fail**

Run `ChromeMenuModelTests`. Expected: FAIL / compile error.

- [ ] **Step 3: Implement**

`ChromeMenuModel.swift`:

```swift
public enum WorkspaceMenuAction: Equatable, Sendable {
    case rename
    case pin
    case unpin
    case changeFolder
    case moveToTopBar
    case close
}

public enum EmptyPinMenuAction: Equatable, Sendable {
    case rename
    case changeFolder
    case moveToTopBar
    case remove
}

public enum TopBarMenuAction: Equatable, Sendable {
    case moveToSidebar
    case rename
    case changeSymbol
    case unpin
}
```

In `WorkspaceMenuModel.entries`, insert before Unpin (pinned) and before Close (unpinned):

```swift
ChromeMenuEntry(label: "Move to Top Bar", action: .moveToTopBar, accessibilityIdentifier: "flock.workspace.menu.moveToTopBar"),
```

In `EmptyPinMenuModel.entries`, before Remove:

```swift
ChromeMenuEntry(label: "Move to Top Bar", action: .moveToTopBar, accessibilityIdentifier: "flock.pin.menu.moveToTopBar"),
```

Add:

```swift
/// A title-bar workspace's right-click menu.
public enum TopBarMenuModel {
    public static func entries() -> [ChromeMenuEntry<TopBarMenuAction>] {
        [
            ChromeMenuEntry(label: "Move to Sidebar", action: .moveToSidebar, accessibilityIdentifier: "flock.topBar.menu.moveToSidebar"),
            ChromeMenuEntry(label: "Rename", action: .rename, accessibilityIdentifier: "flock.topBar.menu.rename"),
            ChromeMenuEntry(label: "Change Icon\u{2026}", action: .changeSymbol, accessibilityIdentifier: "flock.topBar.menu.changeSymbol"),
            ChromeMenuEntry(label: "Unpin", action: .unpin, accessibilityIdentifier: "flock.topBar.menu.unpin"),
        ]
    }
}
```

In `WorkspaceMenuAction.perform`:

```swift
        case .moveToTopBar:
            viewModel.moveToTopBar(workspace: workspaceID, at: nil)
```

In `WorkspaceMark.swift`'s `EmptyPinMenu` switch:

```swift
                    case .moveToTopBar: viewModel.moveToTopBar(pin: pin.id, at: nil)
```

- [ ] **Step 4: Run to verify they pass**

Run `ChromeMenuModelTests`, then build the app target once: `xcodebuild build -scheme Flock -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD`. Expected: PASS, build succeeds (fix any other exhaustive `switch` over these enums the compiler names).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlockCore/Menus/ChromeMenuModel.swift Sources/Flock/Views/WorkspaceMark.swift Tests/FlockCoreTests/ChromeMenuModelTests.swift
git commit -m "menus: Move to Top Bar on rail rows; top-bar cell menu model"
```

---

### Task 6: Overlay size per workspace, label setting, and the fit rule

**Files:**
- Create: `Sources/FlockCore/Rail/TopBarOverlaySizeStore.swift`
- Create: `Sources/FlockCore/Rail/TopBarLabelStore.swift`
- Modify: `Sources/FlockCore/Geometry/TitleBarFit.swift`
- Test: `Tests/FlockCoreTests/TopBarStoresTests.swift` (new)

**Interfaces:**
- Produces:
  - `TopBarOverlaySizeStore(userDefaults:)`: `size(for: PinID) -> ModalSize`, `select(_:for:)`, `forget(_:)`; key `flock.topBarOverlaySize`
  - `public enum TopBarLabel: String, CaseIterable, Sendable { case iconOnly, iconAndName }` with `displayName`
  - `TopBarLabelStore(userDefaults:)`: `label: TopBarLabel` (default `.iconOnly`), `select(_:)`; key `flock.topBarLabel`
  - `TitleBarFit.showsNames(barWidth:leadingEdge:noticesWidth:namedStripWidth:gap:) -> Bool`
  - Unpinning forgets the pin's size: the title-bar cell calls `sizes.forget(id)` right after `viewModel.unpinTopBar(id)` (Task 7). The view model never sees the size store.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlockCore

@MainActor
final class TopBarStoresTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "flock-topbar-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testSizeDefaultsToMediumAndPersistsPerPin() {
        let defaults = defaults()
        let a = PinID(rawValue: "a"), b = PinID(rawValue: "b")
        let store = TopBarOverlaySizeStore(userDefaults: defaults)
        XCTAssertEqual(store.size(for: a), .medium)
        store.select(.large, for: a)
        store.select(.small, for: b)
        let reloaded = TopBarOverlaySizeStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.size(for: a), .large)
        XCTAssertEqual(reloaded.size(for: b), .small)
        reloaded.forget(a)
        XCTAssertEqual(TopBarOverlaySizeStore(userDefaults: defaults).size(for: a), .medium)
    }

    func testAnUnknownStoredSizeReadsAsMedium() {
        let defaults = defaults()
        defaults.set(Data(#"{"a":"huge"}"#.utf8), forKey: TopBarOverlaySizeStore.defaultsKey)
        XCTAssertEqual(TopBarOverlaySizeStore(userDefaults: defaults).size(for: PinID(rawValue: "a")), .medium)
    }

    func testLabelDefaultsToIconOnlyAndPersists() {
        let defaults = defaults()
        XCTAssertEqual(TopBarLabelStore(userDefaults: defaults).label, .iconOnly)
        TopBarLabelStore(userDefaults: defaults).select(.iconAndName)
        XCTAssertEqual(TopBarLabelStore(userDefaults: defaults).label, .iconAndName)
    }

    func testNamesShowOnlyWhenTheNamedStripFits() {
        XCTAssertTrue(TitleBarFit.showsNames(barWidth: 1000, leadingEdge: 300, noticesWidth: 0, namedStripWidth: 400, gap: 16))
        XCTAssertFalse(TitleBarFit.showsNames(barWidth: 700, leadingEdge: 300, noticesWidth: 0, namedStripWidth: 400, gap: 16))
        XCTAssertFalse(TitleBarFit.showsNames(barWidth: 1000, leadingEdge: 300, noticesWidth: 300, namedStripWidth: 400, gap: 16))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run `TopBarStoresTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

`TopBarOverlaySizeStore.swift`:

```swift
import Foundation
import Observation

/// The top-bar overlay's size, one per pin, in the shared modal's three sizes.
@MainActor
@Observable
public final class TopBarOverlaySizeStore {
    public static let defaultsKey = "flock.topBarOverlaySize"

    public private(set) var sizes: [PinID: ModalSize]

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let raw = userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        sizes = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ModalSize(rawValue: value).map { (PinID(rawValue: key), $0) }
        })
    }

    public func size(for pin: PinID) -> ModalSize { sizes[pin] ?? .medium }

    public func select(_ size: ModalSize, for pin: PinID) {
        sizes[pin] = size
        save()
    }

    public func forget(_ pin: PinID) {
        guard sizes.removeValue(forKey: pin) != nil else { return }
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value.rawValue) })
        userDefaults.set(try? JSONEncoder().encode(raw), forKey: Self.defaultsKey)
    }
}
```

`TopBarLabelStore.swift`:

```swift
import Foundation
import Observation

public enum TopBarLabel: String, CaseIterable, Sendable {
    case iconOnly
    case iconAndName

    public var displayName: String {
        switch self {
        case .iconOnly: "Icon only"
        case .iconAndName: "Icon and name"
        }
    }
}

@MainActor
@Observable
public final class TopBarLabelStore {
    public static let defaultsKey = "flock.topBarLabel"

    public private(set) var label: TopBarLabel

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        label = userDefaults.string(forKey: Self.defaultsKey).flatMap(TopBarLabel.init(rawValue:)) ?? .iconOnly
    }

    public func select(_ value: TopBarLabel) {
        label = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
```

`TitleBarFit.swift`, add:

```swift
    /// Names are all or none: a strip that would not fit named between the
    /// view tabs and the notices draws every cell as its icon alone.
    public static func showsNames(
        barWidth: CGFloat, leadingEdge: CGFloat, noticesWidth: CGFloat, namedStripWidth: CGFloat, gap: CGFloat
    ) -> Bool {
        barWidth - leadingEdge - noticesWidth - namedStripWidth >= gap
    }
```

- [ ] **Step 4: Run to verify they pass**

Run `TopBarStoresTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
xcodegen
git add Sources/FlockCore/Rail/TopBarOverlaySizeStore.swift Sources/FlockCore/Rail/TopBarLabelStore.swift Sources/FlockCore/Geometry/TitleBarFit.swift Tests/FlockCoreTests/TopBarStoresTests.swift
Scripts/checks.sh
git commit -m "top bar: overlay size per pin, label setting, names fit rule"
```

---

### Task 7: Title bar strip and the Settings section

**Files:**
- Create: `Sources/Flock/Views/TopBarWorkspaceStrip.swift`
- Create: `Sources/Flock/Views/Settings/TopBarSettingsSection.swift`
- Modify: `Sources/Flock/Views/MainWindow.swift` (`TitleBar` at ~222; its call site at ~78)
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift`
- Modify: `Sources/Flock/FlockApp.swift` (own `TopBarLabelStore` and `TopBarOverlaySizeStore` as `@State`, pass them to `.environment(...)` beside `rtModalSizeStore`, pass the label store to `FlockSettingsView`)
- Modify: `Sources/Flock/Theme/ChromeMetrics.swift` (add `ChromeMetrics.TitleBar.topBarDot`, `topBarMark`, `topBarCellPadding`)
- Test: `Tests/FlockChromeRender/TopBarRenderTests.swift` (new); update `ChromeRenderTests.swift:2705` for the new `FlockSettingsView` argument

**Interfaces:**
- Consumes: Tasks 3-6.
- Produces: `TopBarWorkspaceStrip(theme:viewModel:showsNames:)`; `TitleBar` gains `var viewModel: SessionViewModel? = nil`.

- [ ] **Step 1: Write the render test (fails: types missing)**

Create `TopBarRenderTests.swift`. Host `TitleBar(theme:sessionLabel:connectionState:isDevBuild:viewModel:)` at 1100x38 (and at 640x38 for the fallback), with a view model holding three top-bar pins: `dash` (live, agent status `.working`), `logs` (empty), `board` (live; overlay open via `toggleTopBar`). Provide the environment the title bar reads: `DragCoordinator`, `AllWorkspacesModeStore`, `WorkspaceIdentityStore`, `BoardStore`, `TopBarLabelStore`, `TopBarOverlaySizeStore`, and `DevBuildWatcher?` as nil. Build the session the way `PinnedRailRenderTests.session(unpinned:)` does, then `moveToTopBar(workspace:at:)` each. Copy `snapshot(_:)` and `sample(_:_:)` verbatim from `PinnedRailRenderTests.swift:580-600`.

```swift
    func testCellsDrawIconOnlyWithNamesAndFallBackWhenNarrow() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            for (name, width, label) in [("icons", 1100.0, TopBarLabel.iconOnly), ("names", 1100.0, .iconAndName), ("narrow", 640.0, .iconAndName)] {
                let hosted = try await host(theme, width: width, label: label)
                defer { hosted.window.close() }
                let image = try snapshot(hosted.window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("top-bar-\(name)-\(scheme).png"))
                }
                // A cell is wider than the bar is tall exactly when it carries a name.
                let cells = try hosted.cellFrames()
                XCTAssertEqual(cells.count, 3)
                XCTAssertEqual(cells.allSatisfy { $0.width > ChromeMetrics.TitleBar.height }, name == "names", "\(name) \(scheme)")
                // The working dot is drawn in the theme's working colour at the dash cell's dot position.
                let dot = try XCTUnwrap(sample(image, hosted.dotCenter(for: "dash")))
                XCTAssertEqual(dot, RGB(theme.statusColor(.working)), accuracy: 12)
            }
        }
    }
```

`hosted.cellFrames()` reads the frames of the elements identified `flock.titleBar.topBar.*` from the hosted window's accessibility tree, in window points. Adapt `RGB`, `statusColor` and `accuracy` to the helpers `PinnedRailRenderTests` already uses for its dot assertions; read that file's `assertLayout` first and follow it.

- [ ] **Step 2: Run to verify it fails**

Run `TopBarRenderTests`. Expected: compile failure.

- [ ] **Step 3: Implement the strip**

`TopBarWorkspaceStrip.swift`:

```swift
import FlockCore
import SwiftUI

/// The title bar's top-bar workspaces: one cell per pin, in pin order,
/// drawn like the view tabs.
struct TopBarWorkspaceStrip: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let showsNames: Bool

    @Environment(DragCoordinator.self) private var drag
    @Environment(TopBarOverlaySizeStore.self) private var sizes

    var body: some View {
        let rows = viewModel.railSections(board: nil)?.topBar ?? []
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.pin.id) { index, row in
                TopBarCell(
                    theme: theme, viewModel: viewModel, row: row, showsName: showsNames,
                    isOpen: viewModel.topBarOverlay.openPin == row.pin.id,
                    onUnpin: { sizes.forget(row.pin.id) }
                )
                .offset(x: drag.topBarDisplacement(at: index))
                .reportsDragFrame { drag.setTopBarFrame($0, for: row.pin.id) }
            }
        }
        .reportsDragFrame { drag.setTopBarRegion($0) }
        .onChange(of: rows.map(\.pin.id), initial: true) { _, order in drag.setTopBarOrder(order) }
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
        }
    }
}

private struct TopBarCell: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let row: RailSections.PinnedRow
    let showsName: Bool
    let isOpen: Bool
    let onUnpin: () -> Void

    @Environment(DragCoordinator.self) private var drag
    @State private var picking = false
    @State private var renaming = false

    private var pin: PinnedWorkspace { row.pin }

    var body: some View {
        let empty = row.record == nil
        let status = viewModel.topBarStatus(of: pin)
        GridControlButton(
            theme: theme, shape: AnyShape(Rectangle()),
            restFill: isOpen ? theme.tabRest : .clear,
            restForeground: isOpen ? theme.textStrong : theme.textDim,
            action: { Task { await viewModel.toggleTopBar(pin.id) } }
        ) {
            HStack(spacing: ChromeMetrics.TitleBar.tabGlyphGap) {
                WorkspaceMark(
                    theme: theme, key: pin.identityKey, size: ChromeMetrics.TitleBar.topBarMark,
                    foreground: empty ? theme.textLabel.opacity(ChromeMetrics.WorkspaceRow.emptyPinOpacity) : nil
                )
                .overlay(alignment: .topTrailing) {
                    if let status {
                        StatusDot(
                            status: status.agentStatus, theme: theme, size: ChromeMetrics.TitleBar.topBarDot,
                            isBackground: status.isBackground
                        )
                        .offset(x: ChromeMetrics.TitleBar.topBarDot / 2, y: -ChromeMetrics.TitleBar.topBarDot / 2)
                    }
                }
                if showsName {
                    Text(pin.name)
                        .font(ChromeType.viewTab(selected: isOpen))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, ChromeMetrics.TitleBar.topBarCellPadding)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isOpen { Rectangle().fill(theme.accent).frame(height: ChromeMetrics.TitleBar.tabUnderline) }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.rule).frame(width: ChromeMetrics.ruleWidth).allowsHitTesting(false)
        }
        .background(WindowDragExclusion())
        .opacity(drag.isDragging(pin: pin.id) ? DragVisuals.originOpacity : 1)
        .simultaneousGesture(
            DragGesture(minimumDistance: DragThreshold.movement, coordinateSpace: .named(DragSpace.name))
                .onChanged { value in
                    drag.beginIfIdle(
                        drag.pinDragSubject(pin.id),
                        ghost: DragCoordinator.Ghost(
                            title: pin.name, symbol: "square.grid.2x2",
                            originSize: drag.topBarFrames.first { $0.id == pin.id }?.frame.size ?? .zero
                        ),
                        at: value.startLocation
                    )
                }
        )
        .workspaceSymbolPopover(theme: theme, key: pin.identityKey, isPresented: $picking)
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            InlineRenameField(
                theme: theme, font: ChromeType.workspaceName(selected: false), initialText: pin.name,
                accessibilityIdentifier: "flock.topBar.rename.\(pin.id.rawValue)",
                onCommit: { text in
                    renaming = false
                    Task { await viewModel.renameTopBarPin(pin.id, to: text) }
                },
                onCancel: { renaming = false }
            )
            .frame(width: ChromeMetrics.TitleBar.renameWidth)
            .padding()
        }
        .contextMenu {
            ForEach(TopBarMenuModel.entries(), id: \.accessibilityIdentifier) { entry in
                Button(entry.label) {
                    switch entry.action {
                    case .moveToSidebar: viewModel.moveToSidebar(pin: pin.id, at: nil)
                    case .rename: renaming = true
                    case .changeSymbol: picking = true
                    case .unpin:
                        viewModel.unpinTopBar(pin.id)
                        onUnpin()
                    }
                }
                .accessibilityIdentifier(entry.accessibilityIdentifier)
            }
        }
        .help(pin.name)
        .accessibilityLabel(pin.name)
        .accessibilityIdentifier("flock.titleBar.topBar.\(pin.id.rawValue)")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
```

Check `StatusDot`'s real parameter types in `WorkspaceRail.swift:493` and `ShownStatus`'s property names before compiling, and match them. Add the metrics (`topBarMark = tabGlyphSize + 2`, `topBarDot = 6`, `topBarCellPadding = tabHorizontalPadding`, `renameWidth = 200`) next to the existing `TitleBar` metrics.

The drag-coordinator members this uses (`topBarDisplacement`, `setTopBarFrame`, `setTopBarRegion`, `setTopBarOrder`, `topBarFrames`) arrive in Task 9. For this task add them as no-op stubs on `DragCoordinator` (`func topBarDisplacement(at: Int) -> CGFloat { 0 }`, empty setters, `var topBarFrames: [PinItemFrame] { [] }`), which Task 9 replaces.

- [ ] **Step 4: Wire the strip into `TitleBar`**

In `TitleBar`, add `var viewModel: SessionViewModel? = nil`, `@Environment(TopBarLabelStore.self) private var labels`, and two measured widths: `@State private var noticesWidth: CGFloat = 0` and `@State private var namedStripWidth: CGFloat = 0`. Replace the trailing overlay:

```swift
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                if let viewModel {
                    TopBarWorkspaceStrip(theme: theme, viewModel: viewModel, showsNames: showsNames)
                        .frame(height: ChromeMetrics.TitleBar.height)
                        .fixedSize()
                        // Measured named whatever is drawn, so the fit rule
                        // reads the width names would need.
                        .background {
                            TopBarWorkspaceStrip(theme: theme, viewModel: viewModel, showsNames: true)
                                .fixedSize()
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { namedStripWidth = $0 }
                        }
                }
                HStack(spacing: ChromeMetrics.TitleBar.noticeSpacing) {
                    if let devBuild, devBuild.newerBuildReady {
                        RestartForNewBuildButton(theme: theme, action: devBuild.relaunch)
                    }
                    connectionNotice
                }
                .padding(.horizontal, ChromeMetrics.TitleBar.noticeTrailingPadding)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { noticesWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
        }
```

```swift
    private var showsNames: Bool {
        labels.label == .iconAndName && TitleBarFit.showsNames(
            barWidth: barWidth, leadingEdge: tabsMaxX, noticesWidth: noticesWidth,
            namedStripWidth: namedStripWidth, gap: ChromeMetrics.TitleBar.titleClearance
        )
    }
```

The hidden measuring copy must not report drag frames: give `TopBarWorkspaceStrip` a `var measuring = false` that skips the three `drag` reporters and the context menu when true, and pass `measuring: true` to the hidden copy.

At `MainWindow`'s call site pass `viewModel: viewModel`.

- [ ] **Step 5: Settings section**

`TopBarSettingsSection.swift`:

```swift
import FlockCore
import SwiftUI

struct TopBarSettingsSection: View {
    let store: TopBarLabelStore

    var body: some View {
        Section("Title bar workspaces") {
            Picker(selection: Binding(get: { store.label }, set: { store.select($0) })) {
                ForEach(TopBarLabel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                Text("Show")
                Text("When names do not fit beside the view tabs, every workspace shows its icon alone.")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("flock.settings.topBarLabel")
        }
    }
}
```

Add `let topBarLabelStore: TopBarLabelStore` to `FlockSettingsView`, render `TopBarSettingsSection(store: topBarLabelStore)` after `TitlesSettingsSection`, and pass it from `FlockApp` and from `ChromeRenderTests.swift:2705`.

- [ ] **Step 6: Run, render, look**

```bash
xcodegen
TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=/tmp/flock-topbar xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockChromeRender/TopBarRenderTests
TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=/tmp/flock-topbar xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD -only-testing:FlockChromeRender/ChromeRenderTests
```

Expected: PASS. Open every `top-bar-*.png` and the settings PNG in both schemes and check: cells sit flush right, ruled like the view tabs; the dot is legible on both grounds; the empty cell reads dimmed, not disabled-grey; the open cell matches a selected view tab; the narrow render shows icons only and "flock" hidden, with nothing overlapping. Say plainly what looks wrong and fix it before committing.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/Flock Tests/FlockChromeRender
Scripts/checks.sh
git commit -m "title bar: top-bar workspace cells, icon or name setting"
```

---

### Task 8: The overlay

**Files:**
- Create: `Sources/Flock/Views/TopBarWorkspaceOverlay.swift`
- Modify: `Sources/Flock/Views/MainWindow.swift` (mount; mutual exclusion)
- Test: `Tests/FlockChromeRender/TopBarRenderTests.swift`

**Interfaces:**
- Consumes: `ChromeModal`, `ModalTerminalPane`, `ChromeMetrics.Modal` (Task 1); `CanvasGeometry.resolved`, `PaneBox.frame(in:dividerThickness:)`, `SurfaceGrid.fit`, `TerminalTextSizeStore`; Tasks 4 and 6.
- Produces: `TopBarWorkspaceOverlay(theme:viewModel:)`.

The overlay is a `ChromeModal` user and nothing more: no backdrop, card, title row, size control or close of its own. If it needs something the shared modal lacks, add it to `Sources/Flock/Views/Modal/` (and let the rt modal keep rendering the same).

- [ ] **Step 1: Write the render test (fails: type missing)**

Add to `TopBarRenderTests`: host `TopBarWorkspaceOverlay` at 1100x700 over a solid `theme.canvas`, for a one-pane workspace at `.small` and `.large`, and a two-pane split (`layouts` with two `PaneRect`s side by side) at `.medium`. Surfaces do not attach offscreen, so assert on chrome: the card's frame equals `ChromeModal.boxFrame(... fraction: ChromeMetrics.Modal.sizeFraction(size))`, the title shows the pin's name (`flock.topBar.overlay.title`), and the split has two pane boxes (`flock.topBar.overlay.pane.<id>`). Write `top-bar-overlay-<case>-<scheme>.png`.

- [ ] **Step 2: Run to verify it fails**

Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
import FlockCore
import SwiftUI

/// A top-bar workspace on screen, in the shared modal. Keys go to the
/// focused pane; Esc is the program's, so closing is the modal's close, its
/// backdrop, or the icon again.
struct TopBarWorkspaceOverlay: View {
    let theme: Theme
    let viewModel: SessionViewModel

    @Environment(TopBarOverlaySizeStore.self) private var sizes
    @Environment(TerminalTextSizeStore.self) private var textSize

    var body: some View {
        if let id = viewModel.topBarOverlay.openPin, let pin = viewModel.pins.pin(id) {
            ChromeModal(
                theme: theme, size: sizes.size(for: id),
                onSize: { sizes.select($0, for: id) }, onDismiss: { viewModel.topBarOverlay.close() }
            ) {
                TopBarOverlayTitle(theme: theme, pin: pin, tabCount: tabCount(of: pin))
            } content: { area, scale in
                TopBarOverlayCanvas(
                    theme: theme, viewModel: viewModel, layout: layout(of: pin), area: area, scale: scale,
                    fontSize: textSize.points
                )
            }
        }
    }

    private func layout(of pin: PinnedWorkspace) -> LayoutSnapshot? {
        guard let workspace = pin.workspace, let model = viewModel.userModel,
              let record = model.workspaces.first(where: { $0.workspaceID == workspace }) else { return nil }
        return model.layouts[record.activeTabID]
    }

    private func tabCount(of pin: PinnedWorkspace) -> Int {
        pin.workspace.flatMap { viewModel.userModel?.tabs[$0]?.count } ?? 1
    }
}

/// The modal title row's leading part: symbol, name, and a note while the
/// workspace has grown past one tab.
private struct TopBarOverlayTitle: View {
    let theme: Theme
    let pin: PinnedWorkspace
    let tabCount: Int

    var body: some View {
        HStack(spacing: ChromeMetrics.Modal.TitleRow.gap) {
            WorkspaceMark(theme: theme, key: pin.identityKey, size: ChromeMetrics.WorkspaceRow.mark)
            Text(pin.name)
                .font(ChromeType.modalTitle)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .accessibilityIdentifier("flock.topBar.overlay.title")
            if tabCount > 1 {
                Text("\(tabCount) tabs: only the active one shows here")
                    .font(ChromeType.modalTitle)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
        }
    }
}

/// The tab's panes where herdr's layout puts them, one `ModalTerminalPane`
/// each. Focus is local: nothing is sent to herdr, so its focus and the main
/// view's selection stay where they are.
private struct TopBarOverlayCanvas: View {
    let theme: Theme
    let viewModel: SessionViewModel
    let layout: LayoutSnapshot?
    let area: CGSize
    let scale: CGFloat
    let fontSize: Double

    @State private var focused: PaneID?

    var body: some View {
        if let layout {
            let grid = CanvasGrid(canvas: area, phase: .zero, displayScale: scale)
            let geometry = CanvasGeometry.resolved(
                layout: layout, exported: viewModel.exportedLayout(for: layout.tabID), grid: grid,
                dividerThickness: DividerBand.gutter, liveRatioOverride: nil, composition: .of(layout: layout)
            )
            let cell = TerminalCellMetrics.cell(fontSize: fontSize, scale: scale)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { rect in
                    if let frame = geometry.paneFrames[rect.paneID] {
                        let box = PaneBox.frame(in: frame, dividerThickness: DividerBand.gutter)
                        let fit = SurfaceGrid.fit(inner: box.size, cell: cell)
                        ModalTerminalPane(
                            theme: theme, viewModel: viewModel, paneID: rect.paneID,
                            grid: PTYSize(cols: fit.cols, rows: fit.rows), surfaceSize: fit.size,
                            fontSizePoints: fontSize, isFocused: (focused ?? layout.focusedPane) == rect.paneID,
                            command: nil, onFocus: { focused = rect.paneID }
                        )
                        .id(rect.paneID)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .accessibilityIdentifier("flock.topBar.overlay.pane.\(rect.paneID.rawValue)")
                    }
                }
            }
        } else {
            PaneLoaderView(theme: theme)
        }
    }
}
```

Check `CanvasGrid.init`, `CanvasGeometry.resolved`, `PaneBox.frame` and `CanvasComposition.of` against `PaneCanvas.swift:44-60` and `:160-170`, and match them. If the tab note wants a quieter font than `modalTitle`, add one to `ChromeType` beside `modalTitle` rather than borrowing an rt font.

- [ ] **Step 4: Mount it**

In `MainWindow`, on the outer content, directly before `.overlay(alignment: .top) { TitleBar(...) }`, so the title bar stays clickable above it:

```swift
        // Below the title bar and over everything else, rail included, so it
        // opens from any view and its icon can close it again.
        .overlay {
            TopBarWorkspaceOverlay(theme: theme, viewModel: viewModel)
                .padding(.top, ChromeMetrics.TitleBar.height)
        }
```

Mutual exclusion, beside the existing `.onChange(of: dragCoordinator.isGridShown)`:

```swift
        .onChange(of: viewModel.topBarOverlay.openPin) { _, open in
            guard open != nil else { return }
            commandPalette.close()
            switcher.cancel()
            tabSwitcher.cancel()
            if viewModel.rt.modal != nil { Task { await viewModel.rt.closeModal() } }
        }
        .onChange(of: viewModel.rt.modal != nil) { _, shown in if shown { viewModel.topBarOverlay.close() } }
        .onChange(of: commandPalette.isOpen) { _, open in if open { viewModel.topBarOverlay.close() } }
```

- [ ] **Step 5: Run, render, look**

Run `TopBarRenderTests` with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR`, and `RtModalChromeRenderTests` again (the shared modal must still render rt the same). Expected: PASS. Look at every overlay PNG in both schemes beside an rt modal PNG: same card, same title row, same size control; the split has two boxes with an even gutter; the tab note is legible but quiet. Say what looks wrong and fix it.

- [ ] **Step 6: Commit**

```bash
xcodegen
git add -A Sources/Flock Tests/FlockChromeRender
Scripts/checks.sh
git commit -m "top bar: workspace overlay on the shared modal, size per workspace"
```

---

### Task 9: Drag: reorder in the bar, move between the bar and PINNED

**Files:**
- Modify: `Sources/FlockCore/Mutations/OpPlan.swift` (`DropTarget.topBar(insertIndex:)`)
- Modify: `Sources/FlockCore/Drag/DropResolver.swift` (`DropSurfaces.topBarFrames`, `topBarFrame`; resolve first, before the grid)
- Modify: `Sources/FlockCore/Drag/DropPreview.swift` (`:70`, `:105`, `:196`, `:256`)
- Modify: `Sources/FlockCore/Drag/DragController.swift:174`
- Modify: `Sources/FlockCore/ViewModels/SessionViewModel.swift` (`performPinDrop`, `:2169`)
- Modify: `Sources/Flock/Drag/DragCoordinator.swift` (replace Task 7's stubs; frames, insertion mark, displacement, `surfaces`)
- Modify: `Sources/Flock/FlockApp.swift:244`
- Test: `Tests/FlockCoreTests/DropResolverTests.swift`, `Tests/FlockCoreTests/SessionViewModelTopBarTests.swift`

**Interfaces:**
- Produces:
  - `DropTarget.topBar(insertIndex: Int)`
  - `DropSurfaces.topBarFrames: [PinItemFrame]`, `DropSurfaces.topBarFrame: CGRect?` (init params default `[]`/`nil`)
  - `DragCoordinator.setTopBarOrder(_:)`, `setTopBarFrame(_:for:)`, `setTopBarRegion(_:)`, `topBarFrames`, `topBarDisplacement(at:)`

- [ ] **Step 1: Write the failing tests**

`DropResolverTests` (use the file's existing empty-surfaces builder, adding the two new arguments):

```swift
    func testAPinOverTheTopBarResolvesToAnInsertIndexAlongIt() {
        let frames = [
            PinItemFrame(id: PinID(rawValue: "a"), workspace: nil, frame: CGRect(x: 800, y: 0, width: 40, height: 38)),
            PinItemFrame(id: PinID(rawValue: "b"), workspace: nil, frame: CGRect(x: 840, y: 0, width: 40, height: 38)),
        ]
        let surfaces = <existing builder>(topBarFrames: frames, topBarFrame: CGRect(x: 800, y: 0, width: 80, height: 38))
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 805, y: 10), dragging: .pin(PinID(rawValue: "b")), surfaces: surfaces), .topBar(insertIndex: 0))
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 875, y: 10), dragging: .pin(PinID(rawValue: "a")), surfaces: surfaces), .topBar(insertIndex: 2))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 805, y: 10), dragging: .workspace(WorkspaceID(rawValue: "w1")), surfaces: surfaces))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 805, y: 10), dragging: .pane(PaneID(rawValue: "p1")), surfaces: surfaces))
    }
```

`SessionViewModelTopBarTests`:

```swift
    func testDragsMovePinsBetweenTheBarAndPinnedAndRefuseTwoTabs() async {
        var notices: [String] = []
        let vm = viewModel(notices: { notices.append($0) })
        vm.update(model: model([("w1", "acme"), ("w2", "dash"), ("w3", "logs")], tabs: ["w3": 2]), connection: .live)
        vm.pin(workspace: w1)
        vm.pin(workspace: w2)
        vm.pin(workspace: WorkspaceID(rawValue: "w3"))
        let ids = vm.pins.pins.map(\.id)
        let up = await vm.perform(subject: .pin(ids[1]), target: .topBar(insertIndex: 0))
        XCTAssertEqual(up, .committed)
        XCTAssertEqual(vm.pins.pins(in: .topBar).map(\.name), ["dash"])
        let refused = await vm.perform(subject: .pin(ids[2]), target: .topBar(insertIndex: 1))
        XCTAssertEqual(refused, .noOp)
        XCTAssertEqual(notices.count, 1)
        let down = await vm.perform(subject: .pin(ids[1]), target: .pinnedRail(insertIndex: 0))
        XCTAssertEqual(down, .committed)
        XCTAssertEqual(vm.pins.pins(in: .rail).map(\.name), ["dash", "acme", "logs"])
    }
```

(If `perform(subject:target:)` has another name or outcome type, use what `PinnedRailRenderTests.mount` passes as `commit`.)

- [ ] **Step 2: Run to verify they fail**

Expected: compile failure.

- [ ] **Step 3: Implement FlockCore**

`OpPlan.swift`: add `case topBar(insertIndex: Int)` to `DropTarget`.

`DropResolver.swift`: add the two fields to `DropSurfaces` (stored, init params `topBarFrames: [PinItemFrame] = []`, `topBarFrame: CGRect? = nil`). At the top of `resolveDropTarget`, before the grid check (the bar sits above the grid and the rail):

```swift
    if let bar = surfaces.topBarFrame ?? unionRect(surfaces.topBarFrames.map(\.frame)), bar.contains(point) {
        guard case .pin = dragging else { return nil }
        let centers = surfaces.topBarFrames.map(\.frame.midX)
        return .topBar(insertIndex: insertIndex(of: point.x, centers: centers))
    }
```

(`insertIndex(of:centers:)` counts centres before the value; it is axis-agnostic.)

`DropPreview.swift`: add `.topBar` to the lists at `:70`, `:105` and `:196`; in `dropTargetRect` add:

```swift
    case .topBar(let insertIndex):
        guard let container = surfaces.topBarFrame else { return nil }
        return InsertionBarGeometry.bar(
            atInsertIndex: insertIndex, items: surfaces.topBarFrames.map(\.frame), container: container, axis: .vertical
        )
```

`DragController.swift:174` and `SessionViewModel.swift:2169`: add `.topBar` beside `.pinnedRail`.

`performPinDrop`, before the `case (.pin, _), (_, .pinnedRail):` fallback:

```swift
        case let (.pin(id), .topBar(index)):
            guard let pin = pins.pin(id) else { return .noOp }
            let before = pins.pins
            if pin.placement == .topBar { movePin(id, toInsertIndex: index) } else { moveToTopBar(pin: id, at: index) }
            return pins.pins == before ? .noOp : .committed
```

and change the existing `(.pin(id), .pinnedRail(index))` case so a top-bar pin moves down:

```swift
        case let (.pin(id), .pinnedRail(index)):
            let before = pins.pins
            if pins.pin(id)?.placement == .topBar { moveToSidebar(pin: id, at: index) } else { movePin(id, toInsertIndex: index) }
            return pins.pins == before ? .noOp : .committed
```

Add `(_, .topBar)` to the fallback so a non-pin subject on the bar is a `.noOp`.

- [ ] **Step 4: Implement the coordinator**

In `DragCoordinator`, mirroring the pin bookkeeping (`pinItems`, `setPinFrame`, `pinDisplacement`): a `topBarItems` order + frames (plain `[PinID: CGRect]`, the bar never scrolls), a `topBarRegion: CGRect?`, `isReorderingTopBar` (`if case .topBar? = target`) freezing frame writes during a reorder, `topBarFrames` built in order, and

```swift
    func topBarDisplacement(at index: Int) -> CGFloat {
        guard case .topBar(let insertIndex)? = target else { return 0 }
        let items = topBarFrames.map(\.frame)
        let draggingIndex: Int? = if case .pin(let id)? = activeSubject { topBarFrames.firstIndex { $0.id == id } } else { nil }
        return ReshuffleOffset.displacement(
            forItemAt: index, draggingIndex: draggingIndex, insertIndex: insertIndex,
            extent: draggingIndex.map { ReshuffleOffset.advance(ofItemAt: $0, items: items, axis: .vertical) }
                ?? (items.first?.width ?? ReshuffleOffset.defaultExtent)
        )
    }
```

Pass `topBarFrames` and `topBarRegion` into `surfaces`. Add a `.topBar` arm to `insertionMark` (axis `.vertical`, container `topBarRegion`), and `.topBar` to the `targetHighlight` nil list and `FlockApp.swift:244`. Remove Task 7's stubs.

- [ ] **Step 5: Run to verify**

Run `DropResolverTests`, `DropPreviewTests`, `DragControllerTests`, `SessionViewModelTopBarTests`, `SessionViewModelPinTests`, then build the app. Expected: PASS.

- [ ] **Step 6: Render the drag**

Add to `TopBarRenderTests` a case that begins a `.pin` drag of the `logs` cell and moves it over the first cell's left half (drive `DragCoordinator` the way `PinnedRailRenderTests.testAWorkspaceDraggedOverPinnedOpensAGapThere` does), asserting `drag.target == .topBar(insertIndex: 0)` and writing `top-bar-drag-<scheme>.png`. Look at it: an insertion bar between cells, the other cells slid along, the dragged one ghosted.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
Scripts/checks.sh
git commit -m "drag: reorder top-bar cells and move pins between the bar and PINNED"
```

---

### Task 10: Full verification and hand-over

- [ ] **Step 1: Full suites**

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation -derivedDataPath $DD
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath $DD
Scripts/checks.sh
```

Expected: all green. Fix any existing test whose fixture builds `PinnedWorkspace`, `DropSurfaces` or the menu entry lists positionally.

- [ ] **Step 2: Every render once more, both schemes**

Re-run the render suites with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR` and `TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR` set and look at every `top-bar-*` PNG and the settings PNG. List anything that reads wrong.

- [ ] **Step 3: Hand over**

```bash
Scripts/dev-build.sh
```

Tell Matt to click "New build · Restart" in Flock Dev and try: right-click cswap → Move to Top Bar; the icon's dot; click to open, switch accounts with `s`, Esc inside cswap stays in cswap; Large, then reopen and see Large remembered; drag a rail pin up into the bar and back; Move to Top Bar on a two-tab workspace shows the notice; the Icon and name setting, with the window narrowed until icons return.
