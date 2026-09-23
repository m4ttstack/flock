# flock: notes for agents

Native macOS client for a [herdr](https://github.com/herdrdev/herdr) session:
SwiftUI chrome, one libghostty surface per pane, a bridge process per pane that
drives herdr's control CLI. The repo is public (m4ttstack/flock), so everything
committed here, commit messages included, is public.

## Layout

- `Sources/FlockCore/`: the framework. herdr client and model, reducers, view
  models, every rule that can be tested without a window. No AppKit views.
- `Sources/Flock/`: the app. Views, ghostty surfaces, the bridge's app side,
  stores that run tools (rt, herdr-chat, deck).
- `Tests/FlockCoreTests/`: unit tests. `Tests/FlockChromeRender/`: renders the
  real views offscreen and samples pixels; it compiles `Sources/Flock` minus
  `FlockApp.swift`, `main.swift` and `Updates/Updater.swift`.
  `Tests/FlockUITests/`: end to end against a scratch herdr, run only through
  `Scripts/e2e.sh`.
- `project.yml` generates `Flock.xcodeproj` with `xcodegen`. Edit the yml,
  never the project. Targets: `Flock` (the release app; Sparkle only in its
  Release configuration) and `Flock-dev` ("Flock Dev": own bundle id, DEV icon
  from `Scripts/make-dev-icon.swift`, never updates itself).
- Gitignored inputs a build needs: `Vendor/GhosttyKit.xcframework`
  (`Scripts/libghostty.sh`), `Vendor/Sparkle` (`Scripts/fetch-sparkle.sh`),
  and `Sources/Flock/Resources/herdr-mouse-patch-*`
  (`Scripts/build-herdr-patch.sh`, from a herdr checkout this repo does not
  have). Never delete them; the last one cannot be rebuilt from here.
- `docs/packaging.md`: signing, notarization, the DMG, releasing.
  `.superpowers/`: gitignored work ledgers and reports.

## Build and test

Use a scratch `-derivedDataPath` for every build and test run:

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation -derivedDataPath <scratch>
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation -derivedDataPath <scratch>
Scripts/checks.sh
```

Run `xcodegen` after adding or removing files. Run `Scripts/checks.sh` after
`git add`: its purity gate reads tracked files only, so an unstaged new file
passes unread. CI runs the same three on macos-26 with the newest Xcode.

A UI change is not done until it is rendered in a dark and a light theme and
looked at. Render tests write PNGs when their directory is set, passed through
the test runner with the `TEST_RUNNER_` prefix, e.g.
`TEST_RUNNER_FLOCK_DOCK_RENDER_DIR=<dir> xcodebuild test ...`. The variables
are `FLOCK_{CHROME,DOCK,BOARD,HERDS,GRID,SETTINGS,DEV}_RENDER_DIR`.

## Handing work to Matt

Matt runs production Flock from `/Applications` and tests work in Flock Dev.
When a change is finished and committed, run `Scripts/dev-build.sh`. It swaps
a new `build/dev/Flock-dev.app` into place, and the running Flock Dev shows a
"New build · Restart" pill that relaunches onto it. Tell him to click it. If
Flock Dev is not running: `open build/dev/Flock-dev.app`.

Never quit, kill or launch his apps yourself (anything named Flock, including
`Flock --bridge` children), and never open a GUI app without asking.

## Rules

- **Public repo.** No employer, customer, internal host, ticket id or private
  workspace link anywhere, in code, fixtures, docs or commit messages.
  Fixtures use `acme`. `Scripts/repo-purity.sh` enforces the word list, and
  the last 30 commit messages.
- **herdr.** The herdr source is reference only. Never `herdr server stop`,
  never call `pane.scroll`, never `layout.apply` on live panes. Tests that
  need herdr run against a scratch session (`Scripts/e2e.sh`), never the
  default socket.
- **Tests stay hermetic.** No test may spawn rt, herdr, herdr-chat or deck,
  read `~/.mattstack`, or reach the network. Stores take injectable sources
  (`BoardSources`, `HerdProgressSources`, `ChatRunner`'s environment).
- **Child processes** get `ToolPath.childEnvironment()`. An app opened from
  the Dock, Finder or a Sparkle relaunch has launchd's bare PATH, where rt
  does not live.
- **Swift isolation across Xcode versions.** `XCTestCase.setUp`/`tearDown`
  are not main-actor, so a `@MainActor` test class's statics read there must
  be `nonisolated`.
- **Architecture.** Before changing the terminal, bridge or attach layer, read
  how [Herdglass](https://github.com/buldezir/Herdglass) does it; flock ports
  much of its design (see `THIRD-PARTY-NOTICES.md`).
- **Writing.** No em or en dashes (`checks.sh` fails on them). Comments state
  constraints the code cannot show; no narration, no decision history.

## Releasing

From a clean, pushed `main`:

```bash
Scripts/release-build.sh --version X.Y.Z   # build, sign, notarize, staple; zip + DMG
Scripts/make-appcast.sh build/release X.Y.Z
Scripts/publish-release.sh X.Y.Z           # tag vX.Y.Z and the GitHub release
```

Ask Matt before publishing; a release reaches every installed copy.
`docs/packaging.md` has the details and the traps; the ones that come up most:

- The feed is signed with a key in the login keychain (Sparkle account
  `flock`), backed up in Bitwarden. Both scripts stop early if it is missing;
  `Scripts/restore-signing-key.sh` puts it back.
- The build number is the commit count, and Sparkle orders updates by it, so
  never rewrite `main` below the count of a shipped release.
- If `create-dmg` fails with `Can't get disk (-1728)`, Finder has stopped
  seeing new disk images; it needs a restart (`killall Finder`, with Matt's
  OK), then run the release build again.
- `releases/latest/download/appcast.xml` can serve the previous feed for a
  minute after publishing; the API flips first.
