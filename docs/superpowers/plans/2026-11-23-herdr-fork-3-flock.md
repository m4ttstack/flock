# Flock on the herdr build list Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans (Native, or its Native with reviews variant) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flock installs and updates herdr only from the `m4ttstack/herdr` fork's build list, including on a Mac with no herdr, and flock's own patch files and patch release tooling go away.

**Architecture:** FlockCore gets the build list (decode, version parsing, a pure state decision, copy) and a simpler installer: download, check the list's SHA-256, rename into place, no backup. One app store, `HerdrBuildStore`, replaces `HerdrMousePatchStore` and `HerdrUpdateStore`: it fetches the list, probes the binary, offers Install or Update behind the same confirmation as today, runs `herdr integration install claude` after a fresh install, and keeps the live-handoff server restart. The missing-herdr screen gets an Install button. `patches/herdr/` and the herdr-patch scripts are deleted.

**Tech Stack:** Swift 6, SwiftUI, XCTest, CryptoKit, xcodegen.

**Spec:** the mattstack herdr fork design (`docs/superpowers/specs/2026-11-23-herdr-fork-design.md` in the mattstack repo), section 5 (Flock) and section 2 (the build list). Build list format: `m4ttstack/herdr` branch `mattstack/0.9.5`, `ms/manifests.sh` and `ms/tests/manifests.sh`.

## Global Constraints

- Build list URL: `https://github.com/m4ttstack/herdr/releases/latest/download/herdr-builds.json`. It may 404 until `0.9.5-ms.1` publishes; a 404 is "list unavailable", never an error dialog.
- Build list schema 1 (from `ms/manifests.sh`): `{"schema":1,"newest":"0.9.5-ms.1","builds":[{"version":"0.9.5-ms.1","herdr":"0.9.5","revision":1,"changesServer":true,"assets":{"arm64":{"url":...,"sha256":...},"x86_64":{...}},"supersedes":[sha256...]}],"flockPatchSha256":[12 sha256]}`. Asset URLs are `https://github.com/m4ttstack/herdr/releases/download/v<version>/herdr-macos-aarch64|x86_64`.
- A fork build prints `herdr <base>-ms.<N>` for `--version` (e.g. `herdr 0.9.5-ms.1`); N starts at 1. Stock herdr prints `herdr <base>`.
- Recognise a fork build by its version string, never by a backup file. Recognise a flock-patched herdr (which prints a stock version) by its SHA-256 in `flockPatchSha256`.
- Verify the downloaded file's SHA-256 against the list before it is renamed over the binary.
- No herdr found: install to `~/.local/bin/herdr`, then run `herdr integration install claude`.
- Flock asks every time before replacing an existing herdr (the confirmation dialog stays). A fresh install from the missing screen's button asks nothing more.
- Revert goes; flock writes no backup. Existing `herdr.pre-mouse-backup` files are left alone (rt setup deletes them).
- The live-handoff server restart stays (`server live-handoff --import-exe <path> --expected-version <version>`).
- Flock never runs `herdr update` and never reads `herdr.dev`.
- Tests stay hermetic: no network, no real herdr, no `~/.mattstack`. Everything injectable.
- No em or en dashes anywhere (`Scripts/checks.sh` fails on them). Comments state constraints only.
- Never run a downloaded or built herdr outside `env -i HOME=<a temp dir>`.
- Run `xcodegen` after adding or removing files; `Scripts/checks.sh` after `git add`.

## Review Focus

1. The list is unreachable, 404s, or is not schema 1: the row and missing screen say the list could not be read, the Install button stays usable and retries, nothing on disk changes. Tested in Task 4 (`testListUnavailableLeavesBinaryAndRetriesOnInstall`).
2. rt setup (or anything) replaces herdr while flock downloads: flock refuses to rename over the new binary. Tested in Task 4 (`testBinaryChangedDuringDownloadIsLeftAlone`).
3. A fork build installed by rt setup, with no flock backup anywhere, reads as current or outdated, never stock. Tested in Task 2 (`testOlderForkBuildIsOutdated`, `testNewestVersionStringIsCurrentEvenWithOtherBytes`).
4. `~/.local/bin` does not exist on a fresh Mac: the install creates it. Tested in Task 3 (`testInstallCreatesMissingDirectory`).
5. `herdr integration install claude` fails after a fresh install: herdr stays installed, the missing screen goes away, and the error says what to run. Tested in Task 4 (`testIntegrationFailureKeepsInstallAndSaysWhatToRun`).

---

### Task 1: Build list and build versions (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrArch.swift` (move `HerdrPatchArch` out of `HerdrMousePatchCatalog.swift`, renamed `HerdrArch`; update every user, including tests)
- Create: `Sources/FlockCore/Herdr/HerdrBuildVersion.swift`
- Create: `Sources/FlockCore/Herdr/HerdrBuildList.swift`
- Modify: `Sources/Flock/Machines/LocalHerdrVersion.swift` (use `HerdrBuildVersion.parse(versionOutput:)?.display`)
- Test: `Tests/FlockCoreTests/HerdrBuildVersionTests.swift`, `Tests/FlockCoreTests/HerdrBuildListTests.swift`

**Interfaces:**
- Produces:
  - `public enum HerdrArch: String, CaseIterable, Sendable { case arm64, x86_64; static var current }` (body as today's `HerdrPatchArch`).
  - `public struct HerdrBuildVersion: Hashable, Sendable { let base: String; let forkRevision: Int?; var isMattstackBuild: Bool; var display: String; init?(_ string: String); static func parse(versionOutput: String) -> HerdrBuildVersion?; func isOlder(than: HerdrBuildVersion) -> Bool }`
  - `public struct HerdrBuildList: Equatable, Sendable` with `static let url: URL`, nested `Asset { url: URL; sha256: String }` and `Build { version: HerdrBuildVersion; changesServer: Bool; assets: [HerdrArch: Asset]; supersedes: Set<String> }`, properties `newest: Build`, `builds: [Build]`, `flockPatchSha256: Set<String>`, `static func decode(_ data: Data) -> HerdrBuildList?`, `func build(matching version: HerdrBuildVersion?, sha256: String?) -> Build?`, `func isOutdatedBuild(sha256: String?) -> Bool`.

- [ ] **Step 1: Write the failing version tests** in `HerdrBuildVersionTests`:
  - `testParsesStockAndForkVersionLines`: `parse(versionOutput: "herdr 0.9.5\n")` has base `"0.9.5"`, `forkRevision` nil, `display` `"0.9.5"`, `isMattstackBuild` false; `"herdr 0.9.5-ms.1\n"` has base `"0.9.5"`, revision 1, display `"0.9.5-ms.1"`, `isMattstackBuild` true; `"herdr 0.10.12-ms.14"` revision 14.
  - `testRejectsAnythingElse`: nil for each of `""`, `"herdr"`, `"0.9.5"`, `"herdr v0.9.5"`, `"herdr 0.9.5-beta"`, `"herdr 0.9.5-ms."`, `"herdr 0.9.5-ms.0"`, `"herdr 0.9.5-ms.x"`, `"herdr 0.9.5-ms.1-ms.2"`, `"herdr 0.9."`, `"herdr 9"`, `"Herdr 0.9.5"`, `"herdr  0.9.5"`, `"herdr 0.9.5 build"`, `"herdr 0.9.5\nherdr 0.9.6"`.
  - `testInitTakesTheBareVersion`: `HerdrBuildVersion("0.9.5-ms.2")?.forkRevision == 2`; `HerdrBuildVersion("herdr 0.9.5")` is nil.
  - `testOrdering`: `0.9.5-ms.1` older than `0.9.5-ms.2`; `0.9.5-ms.3` older than `0.9.6-ms.1`; `0.9.9-ms.4` older than `0.9.10-ms.1` (numeric, not lexical); stock `0.9.5` older than `0.9.5-ms.1`; `0.9.5-ms.2` not older than itself.

- [ ] **Step 2: Write the failing list tests** in `HerdrBuildListTests`. Fixture: a JSON string literal in the test shaped exactly like `ms/manifests.sh` output, two builds (`0.9.5-ms.1`, `0.9.5-ms.2`), `newest` `0.9.5-ms.2`, the second build's `supersedes` = the first build's two SHA-256s, and three `flockPatchSha256` values.
  - `testDecodesManifestsOutput`: `newest.version.display == "0.9.5-ms.2"`, `newest.assets[.arm64]?.sha256` matches, `newest.changesServer`, `builds.count == 2`, `flockPatchSha256.count == 3`.
  - `testRejectsOtherSchemas`: nil for `"schema":2`, missing `schema`, `newest` naming a version not in `builds`, a sha256 that is not 64 lowercase hex, an asset URL not starting `https://github.com/m4ttstack/herdr/releases/download/`, and non-JSON bytes.
  - `testUnknownArchKeysAreIgnored`: an extra `"riscv64"` asset decodes; `assets.count == 2`.
  - `testOutdatedBuildRecognition`: `isOutdatedBuild(sha256:)` true for a first-build sha (in `newest.supersedes`) and for a `flockPatchSha256` value; false for the newest sha, for an unknown sha and for nil.
  - `testBuildMatching`: `build(matching: HerdrBuildVersion("0.9.5-ms.1"), sha256: nil)` is the first build; `build(matching: nil, sha256: <second build x86_64 sha>)` is the second; no match is nil.

- [ ] **Step 3: Run them to verify they fail**

Run: `xcodegen && xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests/HerdrBuildVersionTests -only-testing:FlockCoreTests/HerdrBuildListTests -skipPackagePluginValidation -derivedDataPath <scratch>`
Expected: build failure, types not defined.

- [ ] **Step 4: Implement** `HerdrArch.swift`, `HerdrBuildVersion.swift`, `HerdrBuildList.swift`. `decode` uses `Codable` private DTOs and maps to the public types; `url` is the Global Constraints URL. `LocalHerdrVersion.readInstalled` switches to `HerdrBuildVersion.parse(versionOutput:)?.display` so a fork build on both ends compares equal in the machine version warning.

- [ ] **Step 5: Run the two test classes plus `HerdrMousePatchCatalogTests` and `HerdrMousePatchVersionTests`** (same command, add those `-only-testing` flags). Expected: PASS.

- [ ] **Step 6: Commit** `herdr: read the fork's build list and -ms build versions`

### Task 2: Build state, offer and copy (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrBuildDecision.swift` (`HerdrBuildState`, `HerdrBuildDecision`)
- Create: `Sources/FlockCore/Herdr/HerdrBuildOffer.swift`
- Create: `Sources/FlockCore/Herdr/HerdrBuildCopy.swift`
- Test: `Tests/FlockCoreTests/HerdrBuildDecisionTests.swift`, `HerdrBuildOfferTests.swift`, `HerdrBuildCopyTests.swift`

**Interfaces:**
- Consumes: `HerdrBuildVersion`, `HerdrBuildList`, `HerdrArch` (Task 1).
- Produces:
  - `public enum HerdrBuildState: Equatable, Sendable { case missing(installPath: String); case stock(installPath: String, installed: String?, newest: String); case outdated(installPath: String, installed: String?, newest: String); case current(version: String); case notWritable(installPath: String); case listUnavailable(installed: String?) }`
  - `HerdrBuildDecision.decide(binaryExists: Bool, version: HerdrBuildVersion?, sha256: String?, list: HerdrBuildList?, arch: HerdrArch, installPath: String, isWritable: Bool) -> HerdrBuildState`
  - `HerdrBuildOffer.shouldOffer(state:dismissedFor:) -> Bool`, `dismissalToken(for:) -> String?`, `hasAction(for:)`, `bannerHeadline(for:)`, `bannerDetail(for:)`, `bannerActionTitle(for:)`, `bannerDismissTitle`
  - `HerdrBuildCopy` (see Step 4) with `RestartReason { case installed, updated, serverBehind }` and `Confirmation { title, message, confirmButtonTitle }`.

- [ ] **Step 1: Write the failing decision tests.** Use a list whose newest is `0.9.5-ms.2` (as in Task 1's fixture) and arch `.arm64`:
  - `testNoBinaryInWritableLocationIsMissing` → `.missing(installPath:)`; `testNoBinaryUnwritableIsNotWritable` → `.notWritable`.
  - `testNoListIsUnavailable`: stock `0.9.5` with `list: nil` → `.listUnavailable(installed: "0.9.5")`; `testListWithoutThisArchIsUnavailable`.
  - `testNewestShaIsCurrent` (version nil, sha = newest arm64) → `.current(version: "0.9.5-ms.2")`.
  - `testNewestVersionStringIsCurrentEvenWithOtherBytes` (version `0.9.5-ms.2`, unknown sha) → `.current(version: "0.9.5-ms.2")`.
  - `testNewerForkBuildThanListIsCurrent` (`0.9.6-ms.1`) → `.current(version: "0.9.6-ms.1")`.
  - `testOlderForkBuildIsOutdated` (`0.9.5-ms.1`, unknown sha) → `.outdated(installPath:, installed: "0.9.5-ms.1", newest: "0.9.5-ms.2")`.
  - `testFlockPatchedShaIsOutdated` (version `0.9.5`, sha in `flockPatchSha256`) → `.outdated(..., installed: "0.9.5", ...)`; `testSupersededShaIsOutdated` likewise.
  - `testStockIsStock`: `0.9.5` → `.stock(..., installed: "0.9.5", newest: "0.9.5-ms.2")`; stock `0.9.6` (newer than the fork) is also `.stock`; version nil with unknown sha → `.stock(installed: nil)`.
  - `testReplaceableButUnwritableIsNotWritable` for both a stock and an outdated binary.

- [ ] **Step 2: Write the failing offer and copy tests.**
  - Offer: offered only for `.stock` and `.outdated`; token is the state's `newest` for both; `shouldOffer` false once `dismissedFor` equals the token and true again for a different newest; `hasAction(for: nil)` false.
  - Copy: assert each exact string in Step 4 for one representative state per case, plus `actionTitle(for:)` (`missing`/`stock` → `"Install"`, `outdated` → `"Update"`, the rest nil), and that no string in the type contains `"Restore"`, `"backup"` or `"herdr.dev"`.

- [ ] **Step 3: Run them to verify they fail** (`-only-testing:FlockCoreTests/HerdrBuildDecisionTests` etc.). Expected: build failure.

- [ ] **Step 4: Implement.** Decision rules, in order:
  1. `!binaryExists` → `isWritable ? .missing : .notWritable`.
  2. No list, or `list.newest.assets[arch]` nil → `.listUnavailable(installed: version?.display)`.
  3. `sha256 == newest asset sha` → `.current(newest.version.display)`.
  4. `version.isMattstackBuild` and not `version.isOlder(than: newest.version)` → `.current(version.display)`.
  5. Outdated when `version.isMattstackBuild` or `list.isOutdatedBuild(sha256:)`, else stock.
  6. `!isWritable` → `.notWritable`; else `.outdated` / `.stock` with `installed: version?.display`, `newest: newest.version.display`.

  Exact copy (`HerdrBuildCopy`, paths through `displayPath` = `abbreviatingWithTildeInPath`):
  - `heading` `"herdr"`; `rowTitle` `"mattstack build"`.
  - `body(for:)`: missing `"Not installed. flock can install herdr to \(path)."`; stock `"This herdr isn't the mattstack build, so clicks, scrolling and themes don't reach your panes. flock can put herdr \(newest) in its place."`; outdated `"herdr \(newest) is available. flock can replace \(installed ?? "this build") with it."`; current `"Up to date."`; notWritable `"flock can't write to \(path) from this account, so it leaves herdr alone."`; listUnavailable `"flock couldn't read the herdr build list, so it can't check for a newer build."`
  - `installConfirmation(installPath:newest:)`: title `"Install herdr \(newest)?"`, message `"flock will replace \(path) with herdr \(newest), the mattstack build, once its download matches the build list."`, button `"Install"`.
  - `updateConfirmation(installPath:newest:)`: title `"Update herdr to \(newest)?"`, message `"flock will replace \(path) with herdr \(newest) once its download matches the build list."`, button `"Update"`.
  - `restartHeadline`: installed `"herdr is installed"`, updated `"herdr is updated"`, serverBehind `"herdr's server is out of date"`. `restartDetail(for:restartsServer:)`: serverBehind `"A restart keeps your panes running."`; else restartsServer `"Restart herdr to finish; panes keep running."`; else `"Restart Flock so your panes pick it up."`.
  - Carried over unchanged from `HerdrMousePatchCopy`: `restartActionTitle`, `serverRestartActionTitle`, `serverRestartProgressTitle`, `restartActionTitle(restartsServer:)`, `serverRestartConfirmation`, `serverRestartFailedBanner`, `serverRestartFailure(_:)`.
  - Missing screen: `missingHint` `"flock can install the mattstack build of herdr for you."`, `missingInstallTitle` `"Install herdr"`, `missingInstallingTitle` `"Installing herdr\u{2026}"`.
  - Errors (`message(for:)` lives in the store, Task 4, but its strings here): `downloadFailed` `"Couldn't download herdr. Check your connection and try again."`, `checksumMismatch` `"The download didn't match the build list. Nothing was changed."`, `listUnreadable` `"flock couldn't read the herdr build list. Check your connection and try again."`, `herdrChanged` `"herdr changed while the new build downloaded. Nothing was changed."`, `notWritable` `"herdr's install location is not writable."`, `renameFailed` `"The file move failed partway through."`, `integrationFailed` `"herdr is installed, but its Claude integration didn't install. Run herdr integration install claude in a terminal."`
  - Offer: headline stock `"This herdr isn't the mattstack build"`, outdated `"herdr \(newest) is available"`; detail stock `"flock can install it so clicks, scrolling and themes reach your panes."`, outdated `"flock can update it without closing your panes."`; action stock `"Install"`, outdated `"Update"`; dismiss `"Not now"`.
  - Pill: `pillTitle(newest:)` `"herdr \(newest)"`, `pillHelp` `"A newer herdr is available. Open Settings to update."`

- [ ] **Step 5: Run the three test classes.** Expected: PASS.

- [ ] **Step 6: Commit** `herdr: decide install state from the build list`

### Task 3: Downloader and installer (FlockCore)

**Files:**
- Create: `Sources/FlockCore/Herdr/HerdrBuildInstaller.swift`
- Rename: `HerdrMousePatchDownloader.swift` → `HerdrBuildDownloader.swift` (`HerdrBuildDownloader`, protocol `HerdrDownloadTransport`; keep `HerdrPatchProgressThrottle` there as `HerdrDownloadProgressThrottle`)
- Modify: call sites in `Sources/Flock/Herdr/HerdrMousePatchStore.swift`, `Sources/Flock/Herdr/URLSessionPatchTransport.swift` (rename file to `URLSessionDownloadTransport.swift`, cache folder `herdr-builds`) and the render tests, mechanically
- Test: rename `HerdrMousePatchDownloaderTests.swift` → `HerdrBuildDownloaderTests.swift`; create `HerdrBuildInstallerTests.swift`

**Interfaces:**
- Consumes: `HerdrBuildVersion` (Task 1).
- Produces:
  - `HerdrBuildDownloader.fetch(url: URL, sha256: String, fileName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String` (same cache, partial-file and quarantine behaviour as today; `Failure { case transport, checksumMismatch }`); `static func sha256(ofFileAt: URL) throws -> String`.
  - `HerdrBuildInstaller.Probe: Equatable, Sendable { exists: Bool; isWritable: Bool; version: HerdrBuildVersion?; sha256: String? }`
  - `HerdrBuildInstaller.probe(binaryPath: String, fileManager: FileManager = .default, readVersionOutput: (String) -> String?) -> Probe`: for a missing binary, `exists` false, version and sha nil, `readVersionOutput` not called, `isWritable` from the nearest existing ancestor directory.
  - `HerdrBuildInstaller.install(artifactPath: String, binaryPath: String, sha256: String, fileManager: FileManager = .default) throws` with `InstallError: Error, Equatable { case sourceUnreadable, checksumMismatch, destinationNotWritable, renameFailed(errno: Int32) }`.
  - `HerdrBuildInstaller.fileName(for version: HerdrBuildVersion, arch: HerdrArch) -> String` = `"herdr-\(version.display)-\(arch.rawValue)"`.

- [ ] **Step 1: Write the failing installer tests** (temp directory tree, fake binaries are small byte files):
  - `testInstallCreatesMissingDirectory`: binary path `<tmp>/home/.local/bin/herdr` with no `.local`; after install the file exists with mode 0755 and the artifact's bytes.
  - `testReplacesWithoutBackup`: an existing binary is replaced; the directory holds only `herdr` afterwards (no `.pre-mouse-backup`, no staging file).
  - `testMismatchedArtifactLeavesBinaryAlone`: wrong `sha256` throws `.checksumMismatch`; the old bytes are still in place; no staging file left.
  - `testUnwritableDirectoryThrows` (chmod 0555 on the directory) → `.destinationNotWritable`.
  - `testUnreadableArtifactThrows` → `.sourceUnreadable`.
  - `testProbeOfMissingBinary`: `exists` false, `isWritable` true under a writable temp home, the version closure never called.
  - `testProbeReadsVersionAndSha`: version from the closure's `"herdr 0.9.5-ms.1\n"`, sha equals `HerdrBuildDownloader.sha256(ofFileAt:)`.

- [ ] **Step 2: Port the downloader tests** to the new names and the `fetch(url:sha256:fileName:progress:)` signature; same assertions as today.

- [ ] **Step 3: Run** `-only-testing:FlockCoreTests/HerdrBuildInstallerTests -only-testing:FlockCoreTests/HerdrBuildDownloaderTests`. Expected: FAIL (types missing).

- [ ] **Step 4: Implement.** `install`: check readable, create the parent directory (`withIntermediateDirectories`), check writable, copy to `<binary>.flock-staging`, chmod 0755, compare the staging file's SHA-256 to `sha256` (remove staging and throw on mismatch), remove `com.apple.quarantine` from staging, then `rename(2)` staging over the binary (a running herdr keeps its inode). No backup, no post-rename verification.

- [ ] **Step 5: Run the two classes, then the whole `FlockCoreTests` target and the `FlockChromeRender` scheme** (the call-site renames touch both). Expected: PASS.

- [ ] **Step 6: Commit** `herdr: install a build by its list SHA-256, with no backup`

### Task 4: `HerdrBuildStore` (app)

**Files:**
- Create: `Sources/Flock/Herdr/HerdrBuildStore.swift`
- Create: `Sources/Flock/Herdr/HerdrBuildListFetcher.swift`
- Modify: `Sources/Flock/Herdr/HerdrToolStore.swift` (add `recheck()`)
- Test: `Tests/FlockChromeRender/HerdrBuildStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3; `HerdrCommandRunner` and `ProcessHerdrCommandRunner` (`HerdrUpdateRunner.swift`); `HerdrServerBinary`; `HerdrServerRestart.failureReason(output:)`; `HerdrUpdateRun.liveHandoffArguments(binaryPath:expectedVersion:)` and `HerdrUpdateRun.handedOff(status:output:)`.
- Produces (`@MainActor @Observable final class HerdrBuildStore`):
  - `init(resolveBinaryPath: @escaping () -> String? = { ToolPath.resolve("herdr") }, defaultInstallPath: String = NSHomeDirectory() + "/.local/bin/herdr", fetchList: @escaping @Sendable () async -> HerdrBuildList? = HerdrBuildListFetcher.fetch, downloader: HerdrBuildDownloader = .standard, fileManager: FileManager = .default, defaults: UserDefaults = .standard, readVersionOutput: @escaping (String) -> String? = { HerdrVersionReader().read(binaryPath: $0) }, arch: HerdrArch = .current, now: @escaping () -> Date = Date.init, serverSocketPath: @escaping () -> String? = { nil }, probeServer: ..., runner: HerdrCommandRunner = ProcessHerdrCommandRunner(), relaunch: @escaping () -> Void = { AppRelaunch.relaunch() }, onInstalled: @escaping () -> Void = {})`
  - Read state: `state: HerdrBuildState?`, `list: HerdrBuildList?`, `phase: Phase { idle, downloading(Double), installing }`, `pendingConfirmation: PendingConfirmation? { action: install | restartServer; confirmation: HerdrBuildCopy.Confirmation; source: banner | settings }`, `lastErrorMessage`, `bannerErrorMessage`, `restartReason: HerdrBuildCopy.RestartReason?`, `binaryPath`, `binaryVersion: HerdrBuildVersion?`, `serverBinary`, `serverRestarting`, `serverRestartError`.
  - Derived: `shouldOfferBanner`, `showsBanner`, `needsServerRestart`, `restartPrompt`, `bannerRestartPrompt`, `availableUpdate: String?` (the newest version when `state` is `.outdated`, else nil).
  - Actions: `refresh()`, `reprobe()`, `refreshList() async`, `requestInstall(source:)`, `installMissing()`, `confirmPendingAction()`, `cancelPendingConfirmation()`, `dismissBannerOffer()`, `dismissServerBehindBanner()`, `requestServerRestart(source:)`, `checkServer()`.
  - `HerdrBuildListFetcher.fetch() async -> HerdrBuildList?`: GET `HerdrBuildList.url`, nil for any non-200 or `decode` failure.
  - `HerdrToolStore.recheck()`: probes again and updates `isFound`.

Behaviour to keep from `HerdrMousePatchStore` (read it first): fingerprint-gated probing, the server check, the live-handoff restart and its error copy, banner dismissal stored in `UserDefaults` (new keys `flock.herdrBuild.offerDismissedFor`, `flock.herdrBuild.serverBehindDismissedFor`), confirmations presented per source. New:
- `refresh()` also fetches the list when none was fetched yet or the last fetch is older than one hour (`now`).
- `requestInstall` asks only for `.stock` (install confirmation) and `.outdated` (update confirmation).
- `installMissing()` runs only for `.missing`, with no confirmation, fetching the list first when `list` is nil.
- Install: download the newest build's asset for `arch` under `HerdrBuildInstaller.fileName`, re-probe the target, refuse when its `exists`/`sha256` differ from what the state was decided from, install, then for a fresh install run `herdr integration install claude` through `runner` (non-zero status sets `integrationFailed`, the install stands), call `onInstalled()`, set `restartReason` (`.installed` for stock, `.updated` for outdated, none for a fresh install, which has no server yet), `reprobe()`.
- `needsServerRestart`: `state` is `.current`, the list's build matching the binary has `changesServer`, and `serverBinary == .other`.

- [ ] **Step 1: Write the failing store tests** (temp dirs, a fake transport that writes known bytes, a fake runner recording calls, `fetchList` closures, a scratch `UserDefaults` suite):
  - `testMissingHerdrInstallsWithoutConfirmationAndRunsIntegration`: `.missing` → `installMissing()` → binary at `defaultInstallPath`, runner called with `(path, ["integration", "install", "claude"])`, `onInstalled` called once, `pendingConfirmation` stayed nil, `restartReason` nil.
  - `testIntegrationFailureKeepsInstallAndSaysWhatToRun`: runner status 1 → binary present, `lastErrorMessage == HerdrBuildCopy.integrationFailed`, `onInstalled` still called.
  - `testStockInstallAsksFirst`: `requestInstall(source: .settings)` sets the install confirmation naming the path; nothing on disk changes until `confirmPendingAction()`; afterwards the binary has the build's bytes and `restartReason == .installed`.
  - `testOutdatedUpdateAsksFirst`: binary prints `herdr 0.9.5-ms.1` → update confirmation; after confirm `restartReason == .updated`; `availableUpdate == "0.9.5-ms.2"` before, nil after the reprobe sees the newest sha.
  - `testListUnavailableLeavesBinaryAndRetriesOnInstall`: `fetchList` returns nil → `.listUnavailable`; `installMissing()` on a missing binary with a nil-then-nil list sets `lastErrorMessage == HerdrBuildCopy.listUnreadable` and writes nothing; with nil-then-list it installs.
  - `testChecksumMismatchChangesNothing`: transport writes other bytes → `checksumMismatch` message, old binary intact.
  - `testBinaryChangedDuringDownloadIsLeftAlone`: the transport replaces the binary at the install path before returning → `herdrChanged` message, the replacement is untouched.
  - `testListRefetchedHourly`: two `refresh()` calls 10 minutes apart fetch once; at 61 minutes fetch again.
  - `testBannerOfferAndDismissal`: offered for stock; `dismissBannerOffer()` hides it; a list with a newer `newest` offers it again.
  - `testServerRestartNeededOnlyForCurrentChangesServerBuild`: `.current` with `probeServer` returning `.other` → true; `.onDisk` → false; `.outdated` → false.
  - Port the live-handoff restart cases from `Tests/FlockChromeRender/HerdrServerRestartStoreTests.swift` to this store (success relaunches; refusal sets `serverRestartError`).

- [ ] **Step 2: Run** `xcodegen && xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -only-testing:FlockChromeRender/HerdrBuildStoreTests -skipPackagePluginValidation -derivedDataPath <scratch>`. Expected: FAIL (types missing).

- [ ] **Step 3: Implement `HerdrBuildStore`, `HerdrBuildListFetcher`, `HerdrToolStore.recheck()`.** Error mapping uses the `HerdrBuildCopy` error strings from Task 2.

- [ ] **Step 4: Run the same tests.** Expected: PASS.

- [ ] **Step 5: Commit** `herdr: one store installs and updates from the build list`

### Task 5: Wire the app to `HerdrBuildStore`; delete the patch and update paths

**Files:**
- Modify: `Sources/Flock/FlockApp.swift` (build `HerdrBuildStore` with `onInstalled: { herdrToolStore.recheck() }`; drop `HerdrMousePatchStore` and `HerdrUpdateStore`; pass the build store to the missing screen, `MainWindow`, Settings; keep the activation and `herdrVersion` refresh hooks, calling `buildStore.refresh()`)
- Modify: `Sources/Flock/Views/NoHerdrScreen.swift` (`missing` hint is `HerdrBuildCopy.missingHint`; the missing screen gets a primary action `Install herdr` / `Installing herdr…` disabled while `phase != .idle`, and shows `lastErrorMessage` under it)
- Modify: `Sources/Flock/Views/MainWindow.swift` (banner and restart banner read `HerdrBuildStore` and `HerdrBuildOffer`; the title-bar pill shows when `availableUpdate != nil` and opens Settings on the herdr tab)
- Modify: `Sources/Flock/Views/HerdrUpdatePill.swift` (takes `newest: String`; one style, the current non-warning one; copy from `HerdrBuildCopy`)
- Rename: `Sources/Flock/Views/Settings/HerdrMousePatchRow.swift` → `HerdrBuildRow.swift` (Version row; the `mattstack build` row with `body(for:)` and one action button, Install or Update or none; restart rows; errors; no Restore)
- Modify: `Sources/Flock/Views/Settings/FlockSettingsView.swift` (drop `HerdrUpdateSection` and `herdrUpdateStore`)
- Delete: `Sources/Flock/Herdr/HerdrMousePatchStore.swift`, `HerdrUpdateStore.swift`, `Sources/Flock/Views/Settings/HerdrUpdateSection.swift`; FlockCore `HerdrMousePatchCatalog.swift`, `HerdrMousePatchCopy.swift`, `HerdrMousePatchDecision.swift`, `HerdrMousePatchInstaller.swift`, `HerdrMousePatchOffer.swift`, `HerdrMousePatchVersion.swift`, `HerdrMouseVerbs.swift`; from `HerdrUpdate.swift` delete `HerdrLatestManifest`, `HerdrInstallKind`, `HerdrUpdateNotice`, `HerdrUpdateCopy` (delete the file if nothing is left); from `HerdrUpdateRun.swift` keep only `liveHandoffArguments` and `handedOff` (rename the enum `HerdrLiveHandoff`, update users); `HerdrServerRestart.isNeeded` goes if the store no longer calls it
- Delete their tests: `Tests/FlockCoreTests/HerdrMousePatch*Tests.swift`, `HerdrMouseVerbsTests.swift`, `HerdrUpdateTests.swift`, the `update --handoff` cases of `HerdrUpdateRunTests.swift`; `Tests/FlockChromeRender/HerdrMousePatchStoreTests.swift`, `HerdrUpdateStoreTests.swift`, `HerdrUpdateFlowTests.swift`, `HerdrServerRestartStoreTests.swift` (ported in Task 4)
- Modify: `Tests/FlockChromeRender/ChromeRenderTests.swift`, `ArrangeRenderTests.swift`, `WorkspaceClickLatencyTests.swift`, `NoHerdrScreenTests.swift` (construct `HerdrBuildStore`; replace the herdr settings, update-pill and patch-banner render cases)

**Interfaces:**
- Consumes: `HerdrBuildStore` (Task 4), `HerdrBuildCopy`, `HerdrBuildOffer` (Task 2).

- [ ] **Step 1: Replace the herdr render cases in `ChromeRenderTests`** with, each in light and dark: the herdr Settings tab for `.current`, `.stock`, `.outdated`, `.listUnavailable`, and `.outdated` with a pending update confirmation; the patch banner for `.stock` and `.outdated`; the restart banner for `.installed`; the title bar with the update pill; the missing screen with its Install button, while installing, and with an error. Assert the row's text is the exact `HerdrBuildCopy.body(for:)` string and that no Restore button exists (accessibility identifier `flock.settings.herdrMousePatch.secondaryAction` is absent).

- [ ] **Step 2: Wire, rename and delete** per the file list. `grep -rn "HerdrMousePatch\|HerdrUpdateStore\|HerdrLatestManifest\|herdr.dev\|pre-mouse-backup\|revert" Sources Tests` prints nothing except unrelated uses of "revert".

- [ ] **Step 3: Run** `xcodegen`, then both test commands from `CLAUDE.md` (FlockCoreTests and FlockChromeRender). Expected: PASS.

- [ ] **Step 4: Render and look.** `TEST_RUNNER_FLOCK_SETTINGS_RENDER_DIR=<dir> TEST_RUNNER_FLOCK_CHROME_RENDER_DIR=<dir> xcodebuild test -scheme FlockChromeRender ...`; open every new PNG with the Read tool in both schemes and fix anything that reads wrong (clipped copy, a button with no room, the missing screen growing past its frame).

- [ ] **Step 5: `git add -A && Scripts/checks.sh`**, then commit `herdr: settings, banner, pill and missing screen run on the build list`

### Task 6: Remove flock's patch files and tooling

**Files:**
- Delete: `patches/herdr/` (all five), `Scripts/build-herdr-patch.sh`, `Scripts/publish-herdr-patch.sh`
- Modify: `docs/packaging.md` (replace the herdr mouse patch section, lines 17 to 48, with two sentences: flock installs herdr from the `m4ttstack/herdr` build list at the Global Constraints URL; herdr builds are published from that fork, and the old `herdr-patch-*` releases stay up for older flock copies)
- Modify: `CLAUDE.md` (replace the `patches/herdr/<version>.patch` bullet with one bullet: herdr comes from the `m4ttstack/herdr` fork's build list, read by `HerdrBuildList`; flock carries no herdr patches)
- Modify: anything else `grep -rn "herdr-patch\|build-herdr-patch\|publish-herdr-patch\|patches/herdr" Scripts .github CLAUDE.md README.md docs/packaging.md project.yml` finds (dated specs and plans under `docs/superpowers/` are history and stay)

- [ ] **Step 1: Delete and edit** per the list.
- [ ] **Step 2: Verify** the grep above prints nothing, and `git add -A && Scripts/checks.sh` passes.
- [ ] **Step 3: Commit** `remove flock's herdr patches and herdr-patch release scripts`

### Ship

- [ ] Run `Scripts/dev-build.sh` so Matt can try it in Flock Dev.
- [ ] Push with `git_push`, open a ready PR on `m4ttstack/flock`, hand it to a live pr-usher per the pr-usher-handoff rule.
