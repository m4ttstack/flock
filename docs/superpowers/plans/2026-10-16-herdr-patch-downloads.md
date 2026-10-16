# herdr Patch Downloads and Update Note Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** flock downloads a checksum-pinned mouse patch for whichever herdr 0.9.1+ is installed instead of bundling one, and tells the user when a newer herdr exists, with a clear warning when updating would turn mouse support off.

**Architecture:** Patch source becomes `patches/herdr/<version>.patch` files applied to upstream tags; binaries are published as `herdr-patch-X` GitHub pre-releases on m4ttstack/flock. A checked-in FlockCore catalog pins URL + SHA-256 per version; a FlockCore downloader (injected transport) fetches and verifies into the cache, then the existing installer swaps it in. A separate update check reads `version` from `https://herdr.dev/latest.json`, and a pure FlockCore decision turns (installed, latest, patch state, catalog, Homebrew) into a Settings note and a title bar pill.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15), XCTest, CryptoKit, bash, `gh`, cargo + zig 0.16.0.

**Spec:** `docs/superpowers/specs/2026-10-16-herdr-patch-downloads-design.md`

## Global Constraints

- Public repo: no employer, customer, internal host or ticket id anywhere, commit messages included. `Scripts/checks.sh` after `git add`.
- No em or en dashes in any file or commit message.
- Comments state constraints the code cannot show; no narration, no decision history.
- Tests stay hermetic: no network, no herdr, no real binaries; transports and fetchers are injected.
- Every build/test uses `-derivedDataPath /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/build/dd` (inside the worktree; a path containing "GitHub" trips the worktree guard).
- Run only the targeted tests for files touched (`-only-testing:`); full suites run in CI.
- Run `xcodegen` after adding or removing Swift files.
- In this worktree session the Bash guard refuses compound commands: one plain command per call, absolute paths, multi-file edits via a scratchpad script.
- `herdr-patch-*` releases are always `--prerelease` (Sparkle reads `releases/latest/download/appcast.xml`).
- arm64 only. Supported herdr versions: 0.9.1, 0.9.2, 0.9.3, 0.9.4, 0.9.5.
- Release asset URL shape: `https://github.com/m4ttstack/flock/releases/download/herdr-patch-X/herdr-mouse-patch-X-arm64`.
- Update command copy: `herdr update --handoff`; Homebrew: `brew upgrade herdr`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A download cut off midway or replaced by an HTML error page must never reach the installer: the checksum gate deletes it and herdr stays untouched (Task 4 tests a truncated file and a wrong-content file).
2. A cached patch file that was corrupted on disk after a good download must be re-downloaded, not trusted (Task 4 test).
3. A herdr newer than the catalog (0.9.6 before a flock release) must read as "no patch yet", never offer Install, and never install an older patch over it (Task 3 tests 0.9.6 bytes decide `.unsupportedVersion`).
4. Multi-digit version components: 0.9.10 is newer than 0.9.9, and a preview build newer than stable shows no note (Task 6 tests).
5. A user who clicks Install twice, or opens Settings mid-download, must not start a second download or install (Task 5 test: `requestInstall` is ignored while `phase == .downloading`).

## Decisions taken while planning

- The spec's `.noPatchForVersion` collapses into the existing `.unsupportedVersion`: with the catalog as the only source of versions, a detected version always has a patch, so `.artifactUnavailable` becomes unreachable and is removed. `.unsupportedVersion` covers "older than 0.9.1" and "newer than this flock". Its copy becomes "No mouse patch for this herdr yet. A flock update will add one if herdr is newer than this flock knows."
- The installed version for the update note is the connected server's `herdrVersion` (`viewModel.model?.herdrVersion`), the same value Settings already shows.

## File Structure

| File | Responsibility |
| --- | --- |
| `patches/herdr/0.9.{1..5}.patch` (create) | Patch source per herdr version |
| `Scripts/build-herdr-patch.sh` (rewrite) | Clone upstream tag, apply patch, build to `build/herdr-patches/` |
| `Scripts/publish-herdr-patch.sh` (create) | Sign, checksum, `gh release create --prerelease`, print catalog line |
| `Sources/FlockCore/Herdr/HerdrMousePatchCatalog.swift` (create) | Version → URL + SHA-256 |
| `Sources/FlockCore/Herdr/HerdrMousePatchDownloader.swift` (create) | Cache, download via transport, verify SHA-256 |
| `Sources/FlockCore/Herdr/HerdrUpdate.swift` (create) | Version compare, latest.json parse, Homebrew test, notice decision, copy |
| `Sources/Flock/Herdr/URLSessionPatchTransport.swift` (create) | `HerdrPatchTransport` over URLSession |
| `Sources/Flock/Herdr/HerdrUpdateStore.swift` (create) | Hourly latest.json check; exposes `notice` |
| `Sources/Flock/Views/Settings/HerdrUpdateSection.swift` (create) | Note / warning section on the herdr tab |
| `Sources/Flock/Views/HerdrUpdatePill.swift` (create) | Title bar pill |
| `Sources/Flock/Views/Settings/SettingsTabSelection.swift` (create) | Shared Settings tab so the pill can open herdr |
| `Sources/FlockCore/Herdr/HerdrMousePatchVersion.swift`, `HerdrMousePatchDecision.swift`, `HerdrMousePatchCopy.swift` (modify) | Catalog-driven versions; drop `.artifactUnavailable` |
| `Sources/Flock/Herdr/HerdrMousePatchStore.swift`, `Views/Settings/HerdrMousePatchRow.swift` (modify) | Download phase, progress, errors |
| `Sources/Flock/Herdr/HerdrMousePatchArtifactLocator.swift` + its test (delete) | Bundled lookup is gone |
| `Sources/Flock/Theme/Theme.swift` (modify) | Add `peach` |
| `Sources/Flock/Views/MainWindow.swift`, `Views/Settings/FlockSettingsView.swift`, `FlockApp.swift` (modify) | Wiring |
| `Scripts/release-build.sh`, `.gitignore`, `CLAUDE.md` (modify) | Stop bundling |

---

### Task 1: Patch files and the tag-based build script

**Files:**
- Create: `patches/herdr/0.9.1.patch` … `patches/herdr/0.9.5.patch`
- Rewrite: `Scripts/build-herdr-patch.sh`

**Interfaces:**
- Produces: `Scripts/build-herdr-patch.sh --version X` writes `build/herdr-patches/herdr-mouse-patch-X-arm64`, `herdr-mouse-patch-X-arm64.provenance.txt`, `herdr-mouse-patch-X-arm64.LICENSE`. Exit 0 only if the binary contains `terminal.mouse_capture` and `herdr --version` prints `herdr X`.

- [ ] **Step 1: Export the patch files** (one command each; the herdr checkout at `/Users/matt/Documents/GitHub/herdr` holds the commits)

```bash
mkdir -p /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/patches/herdr
git -C /Users/matt/Documents/GitHub/herdr diff a83af1c8^ a83af1c8 --output=/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/patches/herdr/0.9.1.patch
git -C /Users/matt/Documents/GitHub/herdr diff e2268fd9^ e2268fd9 --output=/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/patches/herdr/0.9.2.patch
git -C /Users/matt/Documents/GitHub/herdr diff 51805c5b^ 51805c5b --output=/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/patches/herdr/0.9.3.patch
cp patches/herdr/0.9.3.patch patches/herdr/0.9.4.patch
cp patches/herdr/0.9.3.patch patches/herdr/0.9.5.patch
```

- [ ] **Step 2: Rewrite `Scripts/build-herdr-patch.sh`**

```bash
#!/bin/bash
# Builds herdr X from its upstream tag with patches/herdr/X.patch applied, for
# publishing as a herdr-patch-X release (Scripts/publish-herdr-patch.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION="0.16.0"
ARCH="$(uname -m)"
UPSTREAM="https://github.com/herdrdev/herdr.git"
HERDR_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) HERDR_VERSION="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: Scripts/build-herdr-patch.sh --version X"
      echo "  builds herdr vX with patches/herdr/X.patch into build/herdr-patches/"
      exit 0 ;;
    *) echo "build-herdr-patch: unknown option $1" >&2; exit 2 ;;
  esac
done

[ -n "$HERDR_VERSION" ] || { echo "build-herdr-patch: --version is required" >&2; exit 2; }
PATCH="patches/herdr/$HERDR_VERSION.patch"
[ -f "$PATCH" ] || { echo "build-herdr-patch: no $PATCH" >&2; exit 2; }

case "$(uname -s)" in
  Darwin) ;;
  *) echo "build-herdr-patch: this builds on macOS only ($(uname -s))" >&2; exit 1 ;;
esac
command -v cargo >/dev/null 2>&1 || { echo "build-herdr-patch: cargo is not on PATH (https://rustup.rs)" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || {
  echo "build-herdr-patch: zig $ZIG_VERSION is not on PATH; herdr's build.rs needs it" >&2; exit 1; }
[ "$(zig version)" = "$ZIG_VERSION" ] || {
  echo "build-herdr-patch: zig is $(zig version), herdr's build.rs requires $ZIG_VERSION" >&2; exit 1; }

OUT="build/herdr-patches"
NAME="herdr-mouse-patch-$HERDR_VERSION-$ARCH"
WORK="$(mktemp -d -t flock-herdr-patch)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "build-herdr-patch: cloning herdr v$HERDR_VERSION"
git clone --quiet --depth 1 --branch "v$HERDR_VERSION" "$UPSTREAM" "$WORK/herdr"
TAG_COMMIT="$(git -C "$WORK/herdr" rev-parse HEAD)"
git -C "$WORK/herdr" apply --index "$PWD/$PATCH"

echo "build-herdr-patch: building (this takes a few minutes)"
CARGO_TARGET_DIR="$WORK/target" ZIG="$(command -v zig)" \
  cargo build --release --manifest-path "$WORK/herdr/Cargo.toml"
BUILT="$WORK/target/release/herdr"
[ -x "$BUILT" ] || { echo "build-herdr-patch: cargo build produced no $BUILT" >&2; exit 1; }

# `grep -c`, never `grep -q`: under pipefail `-q` SIGPIPEs `strings` on the
# first match and the pipeline reports failure exactly when the verb is there.
if [ "$(strings "$BUILT" | grep -cF "terminal.mouse_capture")" -eq 0 ]; then
  echo "build-herdr-patch: built binary carries no terminal.mouse_capture verb" >&2
  exit 1
fi
REPORTED="$("$BUILT" --version)"
[ "$REPORTED" = "herdr $HERDR_VERSION" ] || {
  echo "build-herdr-patch: built binary reports '$REPORTED', expected 'herdr $HERDR_VERSION'" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BUILT" "$OUT/$NAME"
chmod 755 "$OUT/$NAME"
cp "$WORK/herdr/LICENSE" "$OUT/$NAME.LICENSE"
cat > "$OUT/$NAME.provenance.txt" <<EOF
# An Apache-2.0 build of herdr $HERDR_VERSION with patches/herdr/$HERDR_VERSION.patch
# from github.com/m4ttstack/flock applied: mouse events and capture state on
# terminal session control. Not made or endorsed by herdr's maintainers.
herdr_version=$HERDR_VERSION
herdr_tag_commit=$TAG_COMMIT
patch_sha256=$(shasum -a 256 "$PATCH" | cut -d' ' -f1)
zig_version=$ZIG_VERSION
arch=$ARCH
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
echo "build-herdr-patch: built $OUT/$NAME ($(du -sh "$OUT/$NAME" | cut -f1))"
```

- [ ] **Step 3: Build 0.9.5 to prove the flow** (about 4 minutes; run in background)

Run: `/Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/Scripts/build-herdr-patch.sh --version 0.9.5`
Expected: last line `build-herdr-patch: built build/herdr-patches/herdr-mouse-patch-0.9.5-arm64 (...)`.

- [ ] **Step 4: Build 0.9.1 through 0.9.4** the same way, one at a time. Each must end with the `built` line. A failed `git apply` means the patch file is wrong for that tag: stop and report.

- [ ] **Step 5: Commit**

```bash
git add patches/herdr Scripts/build-herdr-patch.sh
Scripts/checks.sh
git commit -m "herdr patch: patch files per version, build from upstream tags"
```

### Task 2: Publish script and the five pre-releases

**Files:**
- Create: `Scripts/publish-herdr-patch.sh`

**Interfaces:**
- Consumes: Task 1's `build/herdr-patches/herdr-mouse-patch-X-arm64{,.provenance.txt,.LICENSE}`.
- Produces: release `herdr-patch-X` with assets `herdr-mouse-patch-X-arm64`, `.sha256`, `.provenance.txt`, `.LICENSE`; stdout ends with a Swift catalog line `HerdrMousePatchEntry(version: "X", sha256: "<hex>"),`. Task 3 pastes these five lines.

- [ ] **Step 1: Write `Scripts/publish-herdr-patch.sh`**

```bash
#!/bin/bash
# Signs a built herdr patch and publishes it as the herdr-patch-X pre-release
# that HerdrMousePatchCatalog points at. Always a pre-release: Sparkle reads
# releases/latest/download/appcast.xml, and a full release here could become
# "latest" and break every installed copy's update feed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: Scripts/publish-herdr-patch.sh X" >&2; exit 2; }
REPO="m4ttstack/flock"
TAG="herdr-patch-$VERSION"
NAME="herdr-mouse-patch-$VERSION-arm64"
DIR="build/herdr-patches"
for f in "$NAME" "$NAME.provenance.txt" "$NAME.LICENSE"; do
  [ -f "$DIR/$f" ] || { echo "publish-herdr-patch: no $DIR/$f; run Scripts/build-herdr-patch.sh --version $VERSION" >&2; exit 1; }
done
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "publish-herdr-patch: $TAG already exists; a published patch is never replaced" >&2
  exit 1
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n1)"
[ -n "$IDENTITY" ] || { echo "publish-herdr-patch: no Developer ID Application identity" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIR/$NAME"
codesign --verify --strict "$DIR/$NAME"

SHA="$(shasum -a 256 "$DIR/$NAME" | cut -d' ' -f1)"
printf '%s  %s\n' "$SHA" "$NAME" > "$DIR/$NAME.sha256"

NOTES="An Apache-2.0 build of herdr $VERSION with [patches/herdr/$VERSION.patch](https://github.com/$REPO/blob/main/patches/herdr/$VERSION.patch) applied, so herdr's terminal session control reports mouse capture to Flock. Flock downloads and verifies this file itself from Settings; it is not made or endorsed by herdr's maintainers.

SHA-256: \`$SHA\`"
gh release create "$TAG" -R "$REPO" --prerelease --title "herdr $VERSION mouse patch" --notes "$NOTES" \
  "$DIR/$NAME" "$DIR/$NAME.sha256" "$DIR/$NAME.provenance.txt" "$DIR/$NAME.LICENSE"

echo "HerdrMousePatchEntry(version: \"$VERSION\", sha256: \"$SHA\"),"
```

`chmod +x Scripts/publish-herdr-patch.sh`.

- [ ] **Step 2: Commit the script before publishing**

```bash
git add Scripts/publish-herdr-patch.sh
Scripts/checks.sh
git commit -m "add Scripts/publish-herdr-patch.sh"
```

Note: the release notes link `patches/herdr/X.patch` on `main`, which resolves once this branch merges.

- [ ] **Step 3: Publish 0.9.1 through 0.9.5** (Matt approved publishing without a further prompt). Run `Scripts/publish-herdr-patch.sh 0.9.1`, then each of 0.9.2 to 0.9.5. Save the five printed catalog lines in the task report.

- [ ] **Step 4: Verify each release is a pre-release and downloadable**

Run: `gh release list -R m4ttstack/flock -L 10`
Expected: five `herdr-patch-0.9.x` rows marked `Pre-release`, and `Flock 0.7.1` still `Latest`.

Run: `curl -sL https://github.com/m4ttstack/flock/releases/download/herdr-patch-0.9.5/herdr-mouse-patch-0.9.5-arm64 | shasum -a 256`
Expected: matches the 0.9.5 catalog line.

### Task 3: The catalog drives supported versions

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrMousePatchCatalog.swift`, `Tests/FlockCoreTests/HerdrMousePatchCatalogTests.swift`
- Modify: `Sources/FlockCore/Herdr/HerdrMousePatchVersion.swift:12`, `HerdrMousePatchDecision.swift`, `HerdrMousePatchCopy.swift`, `Sources/Flock/Views/Settings/HerdrMousePatchRow.swift:75`
- Modify tests: `HerdrMousePatchDecisionTests.swift`, `HerdrMousePatchCopyTests.swift`, `HerdrMousePatchOfferTests.swift`, `HerdrMousePatchVersionTests.swift`

**Interfaces:**
- Produces:

```swift
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let sha256: String
    public var fileName: String          // "herdr-mouse-patch-\(version)-arm64"
    public var url: URL                  // release asset URL
}
public enum HerdrMousePatchCatalog {
    public static let entries: [HerdrMousePatchEntry]
    public static func entry(for version: String) -> HerdrMousePatchEntry?
}
```

`HerdrMousePatchRowState` loses `.artifactUnavailable`. `HerdrMousePatchDecision.decide` loses its `artifactAvailable:` parameter.

- [ ] **Step 1: Write the failing catalog tests**

```swift
import FlockCore
import XCTest

final class HerdrMousePatchCatalogTests: XCTestCase {
    func testEveryEntryHasAReleaseURLAndAFullChecksum() {
        for entry in HerdrMousePatchCatalog.entries {
            XCTAssertEqual(
                entry.url.absoluteString,
                "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(entry.version)/herdr-mouse-patch-\(entry.version)-arm64"
            )
            XCTAssertEqual(entry.sha256.count, 64, entry.version)
            XCTAssertTrue(entry.sha256.allSatisfy { "0123456789abcdef".contains($0) }, entry.version)
        }
    }

    func testVersionsAreUniqueAndRunWithoutGapsFromTheFirst() {
        let versions = HerdrMousePatchCatalog.entries.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
        XCTAssertEqual(versions.first, "0.9.1")
        let patches = versions.compactMap { $0.split(separator: ".").last.flatMap { Int($0) } }
        XCTAssertEqual(patches, Array(1...patches.count), "a herdr version between two patched ones has no patch")
    }

    func testLookupFindsOnlyCataloguedVersions() {
        XCTAssertEqual(HerdrMousePatchCatalog.entry(for: "0.9.5")?.version, "0.9.5")
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.6"))
        XCTAssertNil(HerdrMousePatchCatalog.entry(for: "0.9.0"))
    }

    func testSupportedVersionsAreTheCatalog() {
        XCTAssertEqual(HerdrMousePatchVersion.supported, HerdrMousePatchCatalog.entries.map(\.version))
    }

    /// A herdr newer than this flock must never be read as an older one.
    func testANewerHerdrIsNotDetectedAsACataloguedVersion() {
        XCTAssertNil(HerdrMousePatchVersion.detect(in: Data("herdr 0.9.6 build".utf8)))
    }
}
```

- [ ] **Step 2: Run, expect a compile failure** (`HerdrMousePatchCatalog` undefined)

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrMousePatchCatalogTests -skipPackagePluginValidation -derivedDataPath /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/build/dd`

- [ ] **Step 3: Implement the catalog** with the five lines from Task 2

```swift
import Foundation

/// The herdr patches this flock trusts. A version is patchable only if it is
/// here, and only a download matching its SHA-256 is ever installed. Adding a
/// herdr version is a flock release: build, publish, add one line.
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let sha256: String

    public init(version: String, sha256: String) {
        self.version = version
        self.sha256 = sha256
    }

    public var fileName: String { "herdr-mouse-patch-\(version)-arm64" }

    public var url: URL {
        URL(string: "https://github.com/m4ttstack/flock/releases/download/herdr-patch-\(version)/\(fileName)")!
    }
}

public enum HerdrMousePatchCatalog {
    public static let entries: [HerdrMousePatchEntry] = [
        // Paste the five lines Scripts/publish-herdr-patch.sh printed, 0.9.1 first.
    ]

    public static func entry(for version: String) -> HerdrMousePatchEntry? {
        entries.first { $0.version == version }
    }
}
```

The comment inside `entries` is an instruction to the implementer only; the committed file has the five real lines and no comment there.

- [ ] **Step 4: Drive `supported` from the catalog** in `HerdrMousePatchVersion.swift`:

```swift
    public static var supported: [String] { HerdrMousePatchCatalog.entries.map(\.version) }
```

- [ ] **Step 5: Remove `.artifactUnavailable`.** In `HerdrMousePatchDecision.swift` delete the case and its doc comment, drop the `artifactAvailable` parameter and its `if !artifactAvailable` branch. In `HerdrMousePatchCopy.swift` delete the `.artifactUnavailable` arm in `body(for:)`, remove it from `actionTitle(for:)`'s nil list, delete `supportedList`, and change the `.unsupportedVersion` body to:

```swift
        case .unsupportedVersion:
            return "Not available. flock has no mouse patch for this herdr. If it's newer than herdr "
                + "\(HerdrMousePatchVersion.supported.last ?? ""), a flock update will add one."
```

Update the doc comment on `HerdrMousePatchRowState.unsupportedVersion` to: "No catalogue entry for this herdr: older than the first patch, or newer than this flock knows." In `HerdrMousePatchRow.swift:75` remove `.artifactUnavailable` from the `break` list.

- [ ] **Step 6: Fix the existing tests** that name the removed case or parameter: delete the `artifactAvailable:` argument from every `decide(...)` call in `HerdrMousePatchDecisionTests.swift`, delete the test asserting `.artifactUnavailable` (line ~80) and add in its place:

```swift
    func testAVersionWithNoCatalogueEntryIsUnsupported() {
        XCTAssertEqual(
            HerdrMousePatchDecision.decide(
                hasVerbs: false, hasBackup: false, version: nil, isWritable: true,
                installPath: installPath, backupPath: backupPath
            ),
            .unsupportedVersion
        )
    }
```

Remove the `.artifactUnavailable` lines from `HerdrMousePatchCopyTests.swift:39` and `HerdrMousePatchOfferTests.swift:22`. Any `supportedList` assertion in `HerdrMousePatchCopyTests` is replaced by: `XCTAssertTrue(HerdrMousePatchCopy.body(for: .unsupportedVersion).contains("0.9.5"))`.

- [ ] **Step 7: Run the FlockCore herdr tests**

Run: `xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrMousePatchCatalogTests -only-testing:FlockCoreTests/HerdrMousePatchDecisionTests -only-testing:FlockCoreTests/HerdrMousePatchCopyTests -only-testing:FlockCoreTests/HerdrMousePatchOfferTests -only-testing:FlockCoreTests/HerdrMousePatchVersionTests -skipPackagePluginValidation -derivedDataPath /Users/matt/.mattstack/rt/worktrees/gh-m4ttstack-flock/noble-anvil/build/dd`
Expected: all pass. The app target will not compile yet (`HerdrMousePatchStore` still passes `artifactAvailable:`); Task 5 fixes that, so commit FlockCore only after confirming FlockCoreTests build (they compile the Flock scheme's FlockCore target only).

If the Flock scheme refuses to build tests while the app target is broken, make the minimal store fix now: in `HerdrMousePatchStore.refresh()` delete the `artifactAvailable:` argument line.

- [ ] **Step 8: Commit**

```bash
xcodegen
git add Sources/FlockCore Tests/FlockCoreTests Sources/Flock Flock.xcodeproj
Scripts/checks.sh
git commit -m "herdr patch: catalog of published patches drives supported versions"
```

### Task 4: The verified downloader

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrMousePatchDownloader.swift`, `Tests/FlockCoreTests/HerdrMousePatchDownloaderTests.swift`

**Interfaces:**
- Consumes: `HerdrMousePatchEntry` (Task 3).
- Produces:

```swift
public protocol HerdrPatchTransport: Sendable {
    /// Downloads `url` to `destination`. Throws on any transport or HTTP failure.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}
public struct HerdrMousePatchDownloader: Sendable {
    public enum Failure: Error, Equatable { case transport, checksumMismatch }
    public init(cacheDirectory: URL, transport: HerdrPatchTransport)
    public func fetch(_ entry: HerdrMousePatchEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    public static func sha256(ofFileAt url: URL) throws -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import CryptoKit
import FlockCore
import XCTest

private final class StubTransport: HerdrPatchTransport, @unchecked Sendable {
    var body: Data?
    var error: Error?
    private(set) var calls = 0

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1
        if let error { throw error }
        progress(1)
        try body!.write(to: destination)
    }
}

final class HerdrMousePatchDownloaderTests: XCTestCase {
    private var cache: URL!
    private let good = Data("herdr 0.9.5 terminal.mouse_capture".utf8)

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("flock-patch-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cache)
    }

    private func entry(for data: Data) -> HerdrMousePatchEntry {
        HerdrMousePatchEntry(version: "0.9.5", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testAMatchingDownloadLandsInTheCacheAndIsReturned() async throws {
        let transport = StubTransport()
        transport.body = good
        let path = try await HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
            .fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(path, cache.appendingPathComponent("herdr-mouse-patch-0.9.5-arm64").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), good)
    }

    func testAVerifiedCachedFileIsReusedWithoutDownloading() async throws {
        let transport = StubTransport()
        transport.body = good
        let downloader = HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
        _ = try await downloader.fetch(entry(for: good), progress: { _ in })
        _ = try await downloader.fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(transport.calls, 1)
    }

    func testACachedFileCorruptedOnDiskIsDownloadedAgain() async throws {
        let transport = StubTransport()
        transport.body = good
        let downloader = HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport)
        let path = try await downloader.fetch(entry(for: good), progress: { _ in })
        try Data("corrupted".utf8).write(to: URL(fileURLWithPath: path))
        let again = try await downloader.fetch(entry(for: good), progress: { _ in })
        XCTAssertEqual(transport.calls, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: again)), good)
    }

    func testATruncatedDownloadFailsAndLeavesNothingBehind() async throws {
        let transport = StubTransport()
        transport.body = good.prefix(10)
        await assertFails(.checksumMismatch, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testAnErrorPageInPlaceOfTheBinaryFailsTheChecksum() async throws {
        let transport = StubTransport()
        transport.body = Data("<html>Not Found</html>".utf8)
        await assertFails(.checksumMismatch, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
    }

    func testATransportErrorReportsTransport() async throws {
        let transport = StubTransport()
        transport.error = URLError(.notConnectedToInternet)
        await assertFails(.transport, HerdrMousePatchDownloader(cacheDirectory: cache, transport: transport), entry(for: good))
    }

    private func assertFails(
        _ expected: HerdrMousePatchDownloader.Failure, _ downloader: HerdrMousePatchDownloader, _ entry: HerdrMousePatchEntry,
        line: UInt = #line
    ) async {
        do {
            _ = try await downloader.fetch(entry, progress: { _ in })
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? HerdrMousePatchDownloader.Failure, expected, line: line)
        }
    }
}
```

- [ ] **Step 2: Run, expect compile failure.** `-only-testing:FlockCoreTests/HerdrMousePatchDownloaderTests`

- [ ] **Step 3: Implement**

```swift
import CryptoKit
import Foundation

public protocol HerdrPatchTransport: Sendable {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Puts a catalogue patch in the cache and hands back its path only once its
/// SHA-256 matches the catalogue: the installer never sees an unverified byte.
public struct HerdrMousePatchDownloader: Sendable {
    public enum Failure: Error, Equatable { case transport, checksumMismatch }

    private let cacheDirectory: URL
    private let transport: HerdrPatchTransport

    public init(cacheDirectory: URL, transport: HerdrPatchTransport) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    public func fetch(_ entry: HerdrMousePatchEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = cacheDirectory.appendingPathComponent(entry.fileName)
        if fileManager.fileExists(atPath: cached.path) {
            if (try? Self.sha256(ofFileAt: cached)) == entry.sha256 { return cached.path }
            try fileManager.removeItem(at: cached)
        }

        let partial = cacheDirectory.appendingPathComponent(entry.fileName + ".partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try await transport.download(entry.url, to: partial, progress: progress)
        } catch {
            throw Failure.transport
        }
        guard (try? Self.sha256(ofFileAt: partial)) == entry.sha256 else { throw Failure.checksumMismatch }
        try fileManager.moveItem(at: partial, to: cached)
        // A quarantined helper binary is refused by Gatekeeper when a bridge execs it.
        removexattr(cached.path, "com.apple.quarantine", 0)
        return cached.path
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit**

```bash
xcodegen
git add Sources/FlockCore/Herdr/HerdrMousePatchDownloader.swift Tests/FlockCoreTests/HerdrMousePatchDownloaderTests.swift Flock.xcodeproj
Scripts/checks.sh
git commit -m "herdr patch: checksum-verified downloader with a cache"
```

### Task 5: Install by download; stop bundling

**Files:**
- Create: `Sources/Flock/Herdr/URLSessionPatchTransport.swift`, `Tests/FlockChromeRender/URLSessionPatchTransportTests.swift`
- Modify: `Sources/Flock/Herdr/HerdrMousePatchStore.swift`, `Sources/Flock/Views/Settings/HerdrMousePatchRow.swift`, `Tests/FlockChromeRender/HerdrMousePatchStoreTests.swift`, every `HerdrMousePatchStore(resolveBinaryPath:..., resolveArtifactPath:...)` call site (`ChromeRenderTests.swift:2747, 2813, 4649`, `ArrangeRenderTests.swift:260`, `WorkspaceClickLatencyTests.swift:203`), `Scripts/release-build.sh:153`, `.gitignore:12`, `CLAUDE.md:25-27`
- Delete: `Sources/Flock/Herdr/HerdrMousePatchArtifactLocator.swift`, `Tests/FlockChromeRender/HerdrMousePatchArtifactLocatorTests.swift`

**Interfaces:**
- Consumes: `HerdrMousePatchCatalog.entry(for:)`, `HerdrMousePatchDownloader`, `HerdrPatchTransport`.
- Produces on `HerdrMousePatchStore`:

```swift
enum Phase: Equatable { case idle, downloading(Double), installing }
private(set) var phase: Phase
private(set) var binaryPath: String?          // set by refresh(); Task 7 reads it for Homebrew
init(
    resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") },
    catalog: @escaping (String) -> HerdrMousePatchEntry? = HerdrMousePatchCatalog.entry(for:),
    downloader: HerdrMousePatchDownloader = .standard,
    fileManager: FileManager = .default,
    defaults: UserDefaults = .standard
)
func confirmPendingAction()                    // unchanged signature; install now runs in a Task
var installTask: Task<Void, Never>?            // internal, so tests can await it
```

`HerdrMousePatchDownloader.standard` is an app-side extension: cache `~/Library/Caches/<bundle id>/herdr-patches`, transport `URLSessionPatchTransport()`.

- [ ] **Step 1: Transport test with a stub URLProtocol** (hermetic: no socket is opened)

```swift
import FlockCore
import XCTest

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class URLSessionPatchTransportTests: XCTestCase {
    private func transport() -> URLSessionPatchTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionPatchTransport(session: URLSession(configuration: config))
    }

    private var destination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flock-transport-\(UUID().uuidString)")
    }

    func testA200WritesTheBody() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data("bytes".utf8)
        let out = destination
        defer { try? FileManager.default.removeItem(at: out) }
        try await transport().download(URL(string: "https://example.invalid/p")!, to: out, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: out), Data("bytes".utf8))
    }

    func testANon200Throws() async {
        StubProtocol.status = 404
        StubProtocol.body = Data("<html>".utf8)
        let out = destination
        do {
            try await transport().download(URL(string: "https://example.invalid/p")!, to: out, progress: { _ in })
            XCTFail("a 404 must not count as a download")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
```

- [ ] **Step 2: Implement the transport**

```swift
import FlockCore
import Foundation

struct URLSessionPatchTransport: HerdrPatchTransport {
    struct HTTPStatus: Error { let code: Int }

    var session: URLSession = .shared

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPStatus(code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

extension HerdrMousePatchDownloader {
    static var standard: HerdrMousePatchDownloader {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "flock")
            .appendingPathComponent("herdr-patches")
        return HerdrMousePatchDownloader(cacheDirectory: directory, transport: URLSessionPatchTransport())
    }
}
```

Run `-only-testing:FlockChromeRenderTests/URLSessionPatchTransportTests` (the FlockChromeRender scheme; target name per `project.yml`). Expected PASS.

- [ ] **Step 3: Rewrite the store tests' factory** in `HerdrMousePatchStoreTests.swift`. The patched artifact becomes the stub transport's body; the catalog closure returns an entry whose SHA matches it:

```swift
    private final class FileTransport: HerdrPatchTransport, @unchecked Sendable {
        var body: Data
        init(body: Data) { self.body = body }
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.5)
            try body.write(to: destination)
        }
    }

    private let patched = Data("herdr 0.9.1 terminal.mouse_capture patched build".utf8)

    private func makeStore(catalogued: Bool = true, body: Data? = nil) -> HerdrMousePatchStore {
        let sha = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
        return HerdrMousePatchStore(
            resolveBinaryPath: { [binaryPath] in binaryPath },
            catalog: { catalogued ? HerdrMousePatchEntry(version: $0, sha256: sha) : nil },
            downloader: HerdrMousePatchDownloader(
                cacheDirectory: root.appendingPathComponent("cache"), transport: FileTransport(body: body ?? patched)
            )
        )
    }

    private func confirmAndWait(_ store: HerdrMousePatchStore) async {
        store.confirmPendingAction()
        await store.installTask?.value
    }
```

Add `import CryptoKit`. Remove `artifactPath` from setUp. Convert every test that calls `confirmPendingAction()` for an install to `async` and use `await confirmAndWait(store)`. Replace `testNoArtifactReadsAsArtifactUnavailable` with:

```swift
    func testAnUncataloguedVersionIsUnsupported() {
        XCTAssertEqual(makeStore(catalogued: false).state, .unsupportedVersion)
    }
```

Replace the "failing" half of `testASuccessfulInstallOrRestoreAsksForARestartAndAFailureDoesNot` with a store built with `body: Data("<html>".utf8)`, asserting after `await confirmAndWait(failing)` that `restartReason == nil`, `lastErrorMessage == "The download didn't match what flock expected. Nothing was changed."`, and the binary still reads `"herdr 0.9.1 unpatched build"`.

Add:

```swift
    func testASecondInstallRequestWhileDownloadingIsIgnored() async {
        let store = makeStore()
        store.requestInstall()
        store.confirmPendingAction()
        XCTAssertNotEqual(store.phase, .idle)
        store.requestInstall()
        XCTAssertNil(store.pendingConfirmation)
        await store.installTask?.value
        XCTAssertEqual(store.phase, .idle)
    }
```

- [ ] **Step 4: Run, expect compile failure.** `-only-testing:FlockChromeRenderTests/HerdrMousePatchStoreTests`

- [ ] **Step 5: Change the store**

- Replace `resolveArtifactPath` with `catalog` and `downloader` (init shape above); `refresh()` sets `binaryPath = resolveBinaryPath()` first and no longer passes `artifactAvailable`.
- Add `enum Phase` and `private(set) var phase: Phase = .idle`, and `@ObservationIgnored var installTask: Task<Void, Never>?`.
- `requestInstall()` gains `guard phase == .idle else { return }`.
- `performInstall()` becomes:

```swift
    private func performInstall() {
        guard case .patchable(_, let version) = state, let binaryPath = resolveBinaryPath(),
              let entry = catalog(version) else {
            refresh()
            return
        }
        phase = .downloading(0)
        installTask = Task { [downloader, fileManager] in
            defer { phase = .idle; refresh() }
            do {
                let artifact = try await downloader.fetch(entry) { fraction in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
                }
                phase = .installing
                try HerdrMousePatchInstaller.install(artifactPath: artifact, binaryPath: binaryPath, fileManager: fileManager)
                restartReason = .installed
            } catch {
                lastErrorMessage = Self.message(for: error)
            }
        }
    }
```

- In `message(for:)` add, before `default`:

```swift
        case HerdrMousePatchDownloader.Failure.transport:
            return "Couldn't download the patch. Check your connection and try again."
        case HerdrMousePatchDownloader.Failure.checksumMismatch:
            return "The download didn't match what flock expected. Nothing was changed."
```

and change `sourceUnreadable`'s text to `"The downloaded patch could not be read."`.

- [ ] **Step 6: Show progress in the row.** In `HerdrMousePatchRow.actionButton`, before the existing `if let state`:

```swift
        switch store.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading...") }
                .frame(width: 120)
                .accessibilityIdentifier("flock.settings.herdrMousePatch.progress")
        case .installing:
            ProgressView().controlSize(.small)
        case .idle:
            // existing `if let state ...` button body moves here unchanged
        }
```

- [ ] **Step 7: Update every other call site** to `HerdrMousePatchStore(resolveBinaryPath: { nil })` (the defaults cover the rest). The render at `ChromeRenderTests.swift:2813` that needs a patchable store passes `catalog: { HerdrMousePatchEntry(version: $0, sha256: String(repeating: "0", count: 64)) }`; it never confirms, so no download runs.

- [ ] **Step 8: Delete the locator and stop bundling**

```bash
git rm Sources/Flock/Herdr/HerdrMousePatchArtifactLocator.swift Tests/FlockChromeRender/HerdrMousePatchArtifactLocatorTests.swift
```

- `Scripts/release-build.sh:153`: the loop becomes `for binary in Sources/Flock/Resources/herdr-chat; do`, and the comment above it drops `Scripts/build-herdr-patch.sh`.
- `.gitignore:12`: replace `Sources/Flock/Resources/herdr-mouse-patch-*` with `build/herdr-patches/` only if `build/` is not already ignored (check with `git check-ignore build/herdr-patches/x`); otherwise just delete the line.
- `CLAUDE.md:25-27`: delete the `Sources/Flock/Resources/herdr-mouse-patch-*` bullet text and the "Never delete them; the herdr patch cannot be rebuilt from here" sentence. Add under Layout: "`patches/herdr/<version>.patch`: the mouse patch per herdr version. `Scripts/build-herdr-patch.sh` and `Scripts/publish-herdr-patch.sh` build and publish it as a `herdr-patch-X` pre-release; `HerdrMousePatchCatalog` pins each one's SHA-256."
- Remove the stale artifact from the worktree resources if it was copied in: `rm -f Sources/Flock/Resources/herdr-mouse-patch-*` (gitignored, local only).

- [ ] **Step 9: Run** `-only-testing:FlockChromeRenderTests/HerdrMousePatchStoreTests -only-testing:FlockChromeRenderTests/URLSessionPatchTransportTests`, then `xcodebuild build -scheme Flock ...` to confirm the app compiles. Expected PASS / BUILD SUCCEEDED.

- [ ] **Step 10: Render the herdr row mid-download.** Add to `ChromeRenderTests.swift` (file scope):

```swift
private struct HangingTransport: HerdrPatchTransport {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.4)
        try await Task.sleep(for: .seconds(3600))
    }
}
```

and in the test class:

```swift
    /// The herdr row while a patch downloads. PNGs go to `FLOCK_SETTINGS_RENDER_DIR`.
    func testTheHerdrRowShowsDownloadProgress() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_SETTINGS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flock-download-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let herdr = root.appendingPathComponent("herdr").path
        try Data("herdr 0.9.5 unpatched build".utf8).write(to: URL(fileURLWithPath: herdr))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let store = HerdrMousePatchStore(
                resolveBinaryPath: { herdr },
                catalog: { HerdrMousePatchEntry(version: $0, sha256: String(repeating: "0", count: 64)) },
                downloader: HerdrMousePatchDownloader(
                    cacheDirectory: root.appendingPathComponent("cache"), transport: HangingTransport()
                )
            )
            store.requestInstall()
            store.confirmPendingAction()
            defer { store.installTask?.cancel() }

            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: FlockSettingsView.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView: Form { HerdrMousePatchRow(store: store, herdrVersion: "0.9.5") }
                .formStyle(.grouped)
                .frame(width: FlockSettingsView.size.width, height: 240))
            window.orderFront(nil)
            await settle(window)
            XCTAssertEqual(store.phase, .downloading(0.4), "\(name): the row is not mid-download")
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-herdr-downloading-\(name).png"))
            }
            window.close()
        }
    }
```

If `phase` reads `.downloading(0)` because the progress hop has not landed, `await Task.yield()` twice before the assertion.

- [ ] **Step 11: Look at the two PNGs** (`TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=<scratch dir>`), open them in Preview, and say plainly what reads wrong, if anything.

- [ ] **Step 12: Commit**

```bash
xcodegen
git add -A Sources Tests Scripts/release-build.sh .gitignore CLAUDE.md Flock.xcodeproj
Scripts/checks.sh
git commit -m "herdr patch: install by verified download; stop bundling patches"
```

### Task 6: Update check logic (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrUpdate.swift`, `Tests/FlockCoreTests/HerdrUpdateTests.swift`

**Interfaces:**
- Produces:

```swift
public enum HerdrVersionOrder {
    /// nil when either side is not dotted integers.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool?
}
public enum HerdrLatestManifest {
    /// `version` from herdr.dev/latest.json; nil for anything else.
    public static func version(from data: Data) -> String?
}
public enum HerdrInstallKind {
    public static func isHomebrew(resolvedPath: String) -> Bool
}
public enum HerdrUpdateNotice: Equatable, Sendable {
    case available(latest: String, installed: String, command: String, reinstallAfter: Bool)
    case breaksMouse(latest: String, installed: String, command: String)
    public static func decide(
        installed: String?, latest: String?, patchInstalled: Bool, catalogHasLatest: Bool, homebrew: Bool
    ) -> HerdrUpdateNotice?
}
public enum HerdrUpdateCopy {
    public static func headline(_ notice: HerdrUpdateNotice) -> String
    public static func detail(_ notice: HerdrUpdateNotice) -> String?
    public static func pillTitle(_ notice: HerdrUpdateNotice) -> String
    public static let handoffLead = "Update without closing your panes:"
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import FlockCore
import XCTest

final class HerdrUpdateTests: XCTestCase {
    func testVersionOrderIsNumericPerComponent() {
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.10", than: "0.9.9"), true)
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.5", than: "0.9.5"), false)
        XCTAssertEqual(HerdrVersionOrder.isNewer("0.9.4", than: "0.9.5"), false)
        XCTAssertEqual(HerdrVersionOrder.isNewer("1.0", than: "0.9.5"), true)
        XCTAssertNil(HerdrVersionOrder.isNewer("0.9.x", than: "0.9.5"))
    }

    func testTheManifestVersionIsRead() {
        XCTAssertEqual(HerdrLatestManifest.version(from: Data(#"{"version":"0.9.6","releases":{}}"#.utf8)), "0.9.6")
        XCTAssertNil(HerdrLatestManifest.version(from: Data("<html>".utf8)))
        XCTAssertNil(HerdrLatestManifest.version(from: Data(#"{"tag":"v0.9.6"}"#.utf8)))
    }

    func testHomebrewIsACellarPath() {
        XCTAssertTrue(HerdrInstallKind.isHomebrew(resolvedPath: "/opt/homebrew/Cellar/herdr/0.9.5/bin/herdr"))
        XCTAssertFalse(HerdrInstallKind.isHomebrew(resolvedPath: "/Users/acme/.local/bin/herdr"))
    }

    private func decide(
        installed: String? = "0.9.5", latest: String? = "0.9.6", patchInstalled: Bool = false,
        catalogHasLatest: Bool = false, homebrew: Bool = false
    ) -> HerdrUpdateNotice? {
        HerdrUpdateNotice.decide(
            installed: installed, latest: latest, patchInstalled: patchInstalled,
            catalogHasLatest: catalogHasLatest, homebrew: homebrew
        )
    }

    func testNothingShowsWithoutANewerStableVersion() {
        XCTAssertNil(decide(latest: nil))
        XCTAssertNil(decide(installed: nil))
        XCTAssertNil(decide(latest: "0.9.5"))
        XCTAssertNil(decide(installed: "0.9.7", latest: "0.9.6"), "a preview build ahead of stable")
    }

    func testWithoutThePatchItIsAPlainNote() {
        XCTAssertEqual(
            decide(),
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        )
    }

    func testWithThePatchAndACataloguedLatestItSaysToReinstall() {
        XCTAssertEqual(
            decide(patchInstalled: true, catalogHasLatest: true),
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: true)
        )
    }

    func testWithThePatchAndNoCataloguedLatestItWarns() {
        XCTAssertEqual(
            decide(patchInstalled: true, catalogHasLatest: false),
            .breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff")
        )
    }

    func testHomebrewGetsBrewUpgrade() {
        XCTAssertEqual(
            decide(patchInstalled: true, homebrew: true),
            .breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "brew upgrade herdr")
        )
    }

    func testTheWarningSaysMouseSupportTurnsOff() {
        let notice = HerdrUpdateNotice.breaksMouse(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff")
        XCTAssertEqual(HerdrUpdateCopy.headline(notice), "Updating herdr to 0.9.6 will turn off mouse support in flock")
        XCTAssertEqual(
            HerdrUpdateCopy.detail(notice),
            "flock doesn't have a mouse patch for 0.9.6 yet. Mouse clicks and scrolling in panes stop working until a flock update adds one."
        )
        XCTAssertEqual(HerdrUpdateCopy.pillTitle(notice), "herdr 0.9.6")
    }

    func testThePlainNoteCopy() {
        let reinstall = HerdrUpdateNotice.available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: true)
        XCTAssertEqual(HerdrUpdateCopy.headline(reinstall), "herdr 0.9.6 is available (you have 0.9.5)")
        XCTAssertEqual(HerdrUpdateCopy.detail(reinstall), "Updating removes the mouse patch; reinstall it here afterwards.")
        let plain = HerdrUpdateNotice.available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        XCTAssertNil(HerdrUpdateCopy.detail(plain))
    }
}
```

- [ ] **Step 2: Run, expect compile failure.** `-only-testing:FlockCoreTests/HerdrUpdateTests`

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum HerdrVersionOrder {
    public static func isNewer(_ candidate: String, than installed: String) -> Bool? {
        guard let a = components(candidate), let b = components(installed) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }
}

public enum HerdrLatestManifest {
    public static let url = URL(string: "https://herdr.dev/latest.json")!

    public static func version(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, HerdrVersionOrder.isNewer(version, than: "0") != nil else {
            return nil
        }
        return version
    }
}

public enum HerdrInstallKind {
    /// `herdr update` refuses to run on a Homebrew install.
    public static func isHomebrew(resolvedPath: String) -> Bool {
        resolvedPath.contains("/Cellar/")
    }
}

public enum HerdrUpdateNotice: Equatable, Sendable {
    case available(latest: String, installed: String, command: String, reinstallAfter: Bool)
    case breaksMouse(latest: String, installed: String, command: String)

    public static func decide(
        installed: String?, latest: String?, patchInstalled: Bool, catalogHasLatest: Bool, homebrew: Bool
    ) -> HerdrUpdateNotice? {
        guard let installed, let latest, HerdrVersionOrder.isNewer(latest, than: installed) == true else { return nil }
        let command = homebrew ? "brew upgrade herdr" : "herdr update --handoff"
        if patchInstalled, !catalogHasLatest {
            return .breaksMouse(latest: latest, installed: installed, command: command)
        }
        return .available(latest: latest, installed: installed, command: command, reinstallAfter: patchInstalled)
    }

    public var isWarning: Bool {
        if case .breaksMouse = self { return true }
        return false
    }

    public var command: String {
        switch self {
        case .available(_, _, let command, _), .breaksMouse(_, _, let command): command
        }
    }
}

public enum HerdrUpdateCopy {
    public static let handoffLead = "Update without closing your panes:"
    public static let warningLead = "If you update anyway:"

    public static func headline(_ notice: HerdrUpdateNotice) -> String {
        switch notice {
        case .available(let latest, let installed, _, _): "herdr \(latest) is available (you have \(installed))"
        case .breaksMouse(let latest, _, _): "Updating herdr to \(latest) will turn off mouse support in flock"
        }
    }

    public static func detail(_ notice: HerdrUpdateNotice) -> String? {
        switch notice {
        case .available(_, _, _, let reinstall):
            reinstall ? "Updating removes the mouse patch; reinstall it here afterwards." : nil
        case .breaksMouse(let latest, _, _):
            "flock doesn't have a mouse patch for \(latest) yet. Mouse clicks and scrolling in panes stop working until a flock update adds one."
        }
    }

    public static func pillTitle(_ notice: HerdrUpdateNotice) -> String {
        switch notice {
        case .available(let latest, _, _, _), .breaksMouse(let latest, _, _): "herdr \(latest)"
        }
    }
}
```

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit**

```bash
xcodegen
git add Sources/FlockCore/Herdr/HerdrUpdate.swift Tests/FlockCoreTests/HerdrUpdateTests.swift Flock.xcodeproj
Scripts/checks.sh
git commit -m "herdr update: version order, latest.json, notice decision and copy"
```

### Task 7: Update store, Settings note, title bar pill

**Files:**
- Create: `Sources/Flock/Herdr/HerdrUpdateStore.swift`, `Sources/Flock/Views/Settings/HerdrUpdateSection.swift`, `Sources/Flock/Views/HerdrUpdatePill.swift`, `Sources/Flock/Views/Settings/SettingsTabSelection.swift`, `Tests/FlockChromeRender/HerdrUpdateStoreTests.swift`
- Modify: `Sources/Flock/Theme/Theme.swift`, `Sources/Flock/Views/Settings/FlockSettingsView.swift`, `Sources/Flock/Views/MainWindow.swift` (`TitleBar`), `Sources/Flock/FlockApp.swift`, `Tests/FlockChromeRender/ChromeRenderTests.swift`

**Interfaces:**
- Consumes: `HerdrUpdateNotice.decide`, `HerdrLatestManifest`, `HerdrInstallKind`, `HerdrMousePatchStore.state` / `.binaryPath`, `HerdrMousePatchCatalog.entry(for:)`.
- Produces:

```swift
@MainActor @Observable final class HerdrUpdateStore {
    init(
        patchStore: HerdrMousePatchStore,
        installedVersion: @escaping @MainActor () -> String?,
        fetchLatest: @escaping @Sendable () async -> String? = HerdrUpdateStore.fetchFromHerdr,
        now: @escaping () -> Date = Date.init
    )
    private(set) var latest: String?
    var notice: HerdrUpdateNotice? { get }
    func checkIfDue() async        // at most once per hour; failures leave `latest` unchanged
}
@MainActor @Observable final class SettingsTabSelection { var tab: SettingsTab }
```

- [ ] **Step 1: Store tests**

```swift
import FlockCore
import XCTest

@MainActor
final class HerdrUpdateStoreTests: XCTestCase {
    private final class Box: @unchecked Sendable { var value: String?; var calls = 0 }

    private func makeStore(latest: Box, installed: String? = "0.9.5", now: @escaping () -> Date) -> HerdrUpdateStore {
        HerdrUpdateStore(
            patchStore: HerdrMousePatchStore(resolveBinaryPath: { nil }),
            installedVersion: { installed },
            fetchLatest: { latest.calls += 1; return latest.value },
            now: now
        )
    }

    func testANewerLatestProducesANote() async {
        let box = Box(); box.value = "0.9.6"
        let store = makeStore(latest: box, now: Date.init)
        await store.checkIfDue()
        XCTAssertEqual(
            store.notice,
            .available(latest: "0.9.6", installed: "0.9.5", command: "herdr update --handoff", reinstallAfter: false)
        )
    }

    func testChecksAreAtMostHourly() async {
        let box = Box(); box.value = "0.9.6"
        var clock = Date(timeIntervalSince1970: 0)
        let store = makeStore(latest: box, now: { clock })
        await store.checkIfDue()
        clock += 59 * 60
        await store.checkIfDue()
        XCTAssertEqual(box.calls, 1)
        clock += 2 * 60
        await store.checkIfDue()
        XCTAssertEqual(box.calls, 2)
    }

    func testAFailedFetchShowsNothing() async {
        let box = Box()
        let store = makeStore(latest: box, now: Date.init)
        await store.checkIfDue()
        XCTAssertNil(store.notice)
    }
}
```

- [ ] **Step 2: Implement `HerdrUpdateStore`**

```swift
import FlockCore
import Foundation
import Observation

/// herdr's API does not report its own update check, so this reads the
/// manifest herdr itself reads. Any failure hides the note rather than
/// raising an error: it is a courtesy, not a feature someone is waiting on.
@MainActor
@Observable
final class HerdrUpdateStore {
    private(set) var latest: String?

    @ObservationIgnored private let patchStore: HerdrMousePatchStore
    @ObservationIgnored private let installedVersion: @MainActor () -> String?
    @ObservationIgnored private let fetchLatest: @Sendable () async -> String?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastCheck: Date?

    static let interval: TimeInterval = 60 * 60

    init(
        patchStore: HerdrMousePatchStore,
        installedVersion: @escaping @MainActor () -> String?,
        fetchLatest: @escaping @Sendable () async -> String? = HerdrUpdateStore.fetchFromHerdr,
        now: @escaping () -> Date = Date.init
    ) {
        self.patchStore = patchStore
        self.installedVersion = installedVersion
        self.fetchLatest = fetchLatest
        self.now = now
    }

    var notice: HerdrUpdateNotice? {
        let patchInstalled: Bool = if case .installed = patchStore.state { true } else { false }
        let homebrew = patchStore.binaryPath.map {
            HerdrInstallKind.isHomebrew(resolvedPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        } ?? false
        return HerdrUpdateNotice.decide(
            installed: installedVersion(), latest: latest, patchInstalled: patchInstalled,
            catalogHasLatest: latest.flatMap(HerdrMousePatchCatalog.entry(for:)) != nil, homebrew: homebrew
        )
    }

    func checkIfDue() async {
        if let lastCheck, now().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = now()
        if let version = await fetchLatest() { latest = version }
    }

    nonisolated static func fetchFromHerdr() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: HerdrLatestManifest.url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HerdrLatestManifest.version(from: data)
    }
}
```

Run `-only-testing:FlockChromeRenderTests/HerdrUpdateStoreTests`. Expected PASS.

- [ ] **Step 3: `Theme.peach`.** In `Theme.swift` add `public let peach: Color` after `teal` and `peach = Color(palette.peach)` in `init`.

- [ ] **Step 4: Shared Settings tab.** `SettingsTabSelection.swift`:

```swift
import Observation

/// Lets chrome outside the Settings window (the herdr update pill) pick the
/// tab Settings opens on.
@MainActor
@Observable
final class SettingsTabSelection {
    var tab: SettingsTab
    init(tab: SettingsTab = .general) { self.tab = tab }
}
```

In `FlockSettingsView`: replace `@State private var tab: SettingsTab` with `@Bindable var selection: SettingsTabSelection`; the init keeps `tab: SettingsTab = .general` and gains `selection: SettingsTabSelection? = nil`, setting `self.selection = selection ?? SettingsTabSelection(tab: tab)`; `TabView(selection: $selection.tab)`. Add `herdrUpdateStore: HerdrUpdateStore? = nil` and render `HerdrUpdateSection(store:)` above `HerdrMousePatchRow` in `pane(.herdr)` when non-nil. In `.onAppear` add `Task { await herdrUpdateStore?.checkIfDue() }`.

- [ ] **Step 5: `HerdrUpdateSection.swift`**

```swift
import AppKit
import FlockCore
import SwiftUI

/// Above the mouse patch row on the herdr tab. The warning leads with what
/// breaks; the plain note leads with what is available.
struct HerdrUpdateSection: View {
    let store: HerdrUpdateStore

    var body: some View {
        if let notice = store.notice {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(HerdrUpdateCopy.headline(notice)).fontWeight(.semibold)
                    } icon: {
                        Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.up.circle")
                            .foregroundStyle(notice.isWarning ? Color.orange : Color.accentColor)
                    }
                    if notice.isWarning, let detail = HerdrUpdateCopy.detail(notice) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Text(notice.isWarning ? HerdrUpdateCopy.warningLead : HerdrUpdateCopy.handoffLead)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(notice.command)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notice.command, forType: .string)
                        }
                        .accessibilityIdentifier("flock.settings.herdrUpdate.copy")
                    }
                    if !notice.isWarning, let detail = HerdrUpdateCopy.detail(notice) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(notice.isWarning ? "flock.settings.herdrUpdate.warning" : "flock.settings.herdrUpdate.note")
        }
    }
}
```

Settings uses system styling (see `FlockSettingsView` doc comment), so `Color.orange` here, not the theme.

- [ ] **Step 6: `HerdrUpdatePill.swift`** (modelled on `RestartForNewBuildButton`, `MainWindow.swift:522`)

```swift
import FlockCore
import SwiftUI

struct HerdrUpdatePill: View {
    let theme: Theme
    let notice: HerdrUpdateNotice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.TitleBar.restartGlyphSpacing) {
                Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.up")
                    .font(ChromeType.restartGlyph)
                Text(HerdrUpdateCopy.pillTitle(notice))
                    .font(ChromeType.restartLabel)
            }
            .foregroundStyle(notice.isWarning ? theme.chrome : theme.textStrong)
            .padding(.horizontal, ChromeMetrics.TitleBar.restartHorizontalPadding)
            .padding(.vertical, ChromeMetrics.TitleBar.restartVerticalPadding)
            .background(notice.isWarning ? theme.peach : theme.surface1, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(WindowDragExclusion())
        .help(notice.isWarning ? HerdrUpdateCopy.headline(notice) : "A newer herdr is available. Open Settings to update.")
        .accessibilityIdentifier(notice.isWarning ? "flock.titleBar.herdrUpdate.warning" : "flock.titleBar.herdrUpdate")
    }
}
```

If `WindowDragExclusion` is `private` in `MainWindow.swift`, make it internal.

- [ ] **Step 7: Wire the pill into `TitleBar`.** Add:

```swift
    @Environment(HerdrUpdateStore.self) private var herdrUpdate: HerdrUpdateStore?
    @Environment(SettingsTabSelection.self) private var settingsSelection: SettingsTabSelection?
    @Environment(\.openSettings) private var openSettings
```

In the notices `HStack` (line ~461), after the dev pills and before `connectionNotice`:

```swift
                    if let notice = herdrUpdate?.notice {
                        HerdrUpdatePill(theme: theme, notice: notice) {
                            settingsSelection?.tab = .herdr
                            openSettings()
                        }
                    }
```

and add `|| herdrUpdate?.notice != nil` to `hasNotices`.

- [ ] **Step 8: Wire in `FlockApp`.** Add `@State private var settingsTabSelection = SettingsTabSelection()` and a `HerdrUpdateStore` built from `herdrMousePatchStore` with `installedVersion: { [viewModel] in viewModel.model?.herdrVersion }` (hold it in `@State`, created lazily in the same way the file creates other stores that depend on `viewModel`; follow the existing pattern around line 77-86). Add `.environment(herdrUpdateStore)` and `.environment(settingsTabSelection)` next to `.environment(devBuildWatcher)` (line 363). Pass `herdrUpdateStore:` and `selection: settingsTabSelection` to `FlockSettingsView` (line 719). Run `await herdrUpdateStore.checkIfDue()` on launch and when the app becomes active: add to the existing `NSApplication.didBecomeActiveNotification` handling if there is one, else `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await herdrUpdateStore.checkIfDue() } }` on the main window scene.

- [ ] **Step 9: Renders.** In `ChromeRenderTests.swift`:

1. `testTheHerdrUpdatePillDrawsNeutralAndWarning`: for `tokyo-night` (dark) and `catppuccin-latte` (light), and for each of `.available(... reinstallAfter: false)` and `.breaksMouse(...)`, host a `TitleBar` (as `makeTitleBarWindow` does) with `.environment(store)` where `store` is a `HerdrUpdateStore` whose `fetchLatest` returns `"0.9.6"` and `installedVersion` returns `"0.9.5"`, and whose patch store is `.installed` for the warning case (point `resolveBinaryPath` at a temp file containing `terminal.mouse_capture` with a sibling `.pre-mouse-backup`). Await `checkIfDue()`, settle, snapshot, write `herdr-update-pill-{neutral,warning}-{dark,light}.png` to `FLOCK_CHROME_RENDER_DIR`. Assert the warning case has `theme.palette.peach.hex` pixels in the trailing 200pt of the title bar and the neutral case has none.
2. Extend `testTheSettingsWindowDrawsInBothAppearances` with two extra cases on the herdr tab, `herdr-update-note` and `herdr-update-warning`, passing a `herdrUpdateStore` built the same way. The size assertion still holds (every tab one size).

- [ ] **Step 10: Run** `-only-testing:` the two render tests and `HerdrUpdateStoreTests` with `TEST_RUNNER_FLOCK_CHROME_RENDER_DIR` and `TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR` set to a scratch dir. Expected PASS.

- [ ] **Step 11: Look at every PNG** in both schemes, open them in Preview, and report plainly what reads wrong (pill contrast in light mode, warning text wrapping, code block legibility).

- [ ] **Step 12: Commit**

```bash
xcodegen
git add -A Sources Tests Flock.xcodeproj
Scripts/checks.sh
git commit -m "herdr update: Settings note, mouse warning and title bar pill"
```

### Task 8: End to end in Flock Dev

No code unless something breaks.

- [ ] **Step 1:** `Scripts/dev-build.sh --output /Users/matt/Documents/GitHub/flock/build/dev` (worktree setup per memory: copy `Vendor/GhosttyKit.xcframework`, `Vendor/Sparkle`, `Vendor/libghostty.version`, `Sources/Flock/Resources/herdr-chat*` from the main checkout first, and `git submodule update --init Vendor/ghostty`).
- [ ] **Step 2:** Tell Matt to click "New build · Restart" in Flock Dev. Do not launch, quit or kill any Flock.
- [ ] **Step 3:** With Matt: his herdr is a patched 0.9.3 (`~/.local/bin/herdr`, backup beside it). Settings > herdr should show the update note for 0.9.5 with "reinstall it here afterwards" (0.9.5 is catalogued), and the neutral pill in the title bar. Matt runs `herdr update --handoff`; Settings then shows Install for 0.9.5; Install downloads, verifies and installs; Restart Flock; mouse works in a pane.
- [ ] **Step 4:** Warning path without a real 0.9.6: covered by the Task 7 renders; note in the PR that the live warning appears only once herdr ships a version past the catalog.
- [ ] **Step 5:** Push and open the PR per the repo flow (CodeRabbit, CI green, merge on Matt's confirmation).
