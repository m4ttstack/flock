# Downloading herdr mouse patches, and telling people herdr has updated

## Why this exists

flock patches herdr's CLI so panes can receive mouse events
(`2026-09-20-herdr-mouse-patch-design.md`). The patched binary is built per
herdr version, and today it ships inside the app. Three things have gone wrong
with that:

- **Releases ship one patch.** `release-build.sh` bundles whatever
  `herdr-mouse-patch-*` sits in `Sources/Flock/Resources`, and only 0.9.1 was
  there. Flock 0.7.1 lists 0.9.1, 0.9.2 and 0.9.3 as supported but can only
  patch 0.9.1; everyone else sees "artifact unavailable".
- **The patch source is fragile.** The commits live only in a local herdr
  checkout. `a83af1c8` (0.9.1) is on no branch, and `e2268fd9` (0.9.2) lost its
  branch, so either can be garbage collected.
- **Bundling does not scale.** Each binary is about 23 MB; one per herdr
  version since 0.9.1 would put the app past 150 MB and grow every release.

herdr also ships fast (0.9.4 and 0.9.5 a day apart), and its update
notification only shows in herdr's own TUI, which flock users stop looking at.
Updating herdr also silently removes flock's patch, because `herdr update`
overwrites the binary.

## Decisions

- Patch source lives in this repo as plain patch files; herdr is not forked.
- Binaries are GitHub release assets on `m4ttstack/flock`, one pre-release per
  herdr version. The app bundles none.
- The app trusts a checked-in catalog (version, URL, SHA-256). Supporting a new
  herdr version means a flock release. A signed remote catalog was considered
  and rejected: flock ships often enough that it buys little, and it adds a
  fetch, a signature path and a second use of the signing key.
- Settings shows when a newer herdr exists, how to update without losing
  panes, and a clear warning when updating would turn mouse support off.
- arm64 only, as today.

## 1. Patch source and publishing

**Patch files.** `patches/herdr/<version>.patch`, one per herdr version,
exported with `git format-patch` from the existing commits:

| herdr | applies to tag | from commit |
| --- | --- | --- |
| 0.9.1 | `v0.9.1` | `a83af1c8` |
| 0.9.2 | `v0.9.2` | `e2268fd9` |
| 0.9.3 | `v0.9.3` | `51805c5b` |
| 0.9.4 | `v0.9.4` | `51805c5b` |
| 0.9.5 | `v0.9.5` | `51805c5b` |

Each applies cleanly to its tag (checked 2026-10-16). The 0.9.5 build was
compiled and carries `terminal.mouse_capture`. The 0.9.1 artifact shipped so
far was built from an untagged `master` commit; from now on every build is the
tag plus the patch file.

**Build.** `Scripts/build-herdr-patch.sh --version X` clones
`https://github.com/herdrdev/herdr` at tag `vX` into a temp directory, runs
`git apply patches/herdr/X.patch`, and builds with cargo (zig 0.16.0, as now).
It no longer reads a local herdr checkout or requires branches. Output goes to
`build/herdr-patches/herdr-mouse-patch-X-arm64` with its `.provenance.txt`
(herdr tag commit, patch file SHA-256, zig version, built_at) and herdr's
`LICENSE`. The existing verb check (`terminal.mouse_capture` present) stays.
`--check` is dropped; provenance records what was built.

**Publish.** New `Scripts/publish-herdr-patch.sh X`:

1. Signs the binary with the Developer ID identity `release-build.sh` uses
   (hardened runtime, timestamp).
2. Writes `herdr-mouse-patch-X-arm64.sha256`.
3. Creates release `herdr-patch-X` on `m4ttstack/flock` with
   `gh release create --prerelease`, uploading the binary, `.sha256`,
   `.provenance.txt` and `LICENSE`. The notes say it is an Apache-2.0 build of
   herdr X carrying `patches/herdr/X.patch`, not endorsed by herdr's
   maintainers.
4. Prints the catalog line to paste into `HerdrMousePatchCatalog`.

Rule: these releases are always pre-releases. Sparkle reads
`releases/latest/download/appcast.xml`; a non-pre-release `herdr-patch-*`
could become "latest" and break every installed copy's update feed. The script
refuses to run if `gh release view herdr-patch-X` already exists, and it asks
nothing of the appcast.

**Release build.** `release-build.sh` stops bundling and signing
`herdr-mouse-patch-*`. `HerdrMousePatchArtifactLocator` and the gitignore
entry for the bundled artifact are removed.

## 2. Downloading and installing

**Catalog** (`Sources/FlockCore/Herdr/HerdrMousePatchCatalog.swift`). A
checked-in table:

```swift
public struct HerdrMousePatchEntry: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String
}
public enum HerdrMousePatchCatalog {
    public static let entries: [HerdrMousePatchEntry]
    public static func entry(for version: String) -> HerdrMousePatchEntry?
}
```

URLs are `https://github.com/m4ttstack/flock/releases/download/herdr-patch-X/herdr-mouse-patch-X-arm64`.
`HerdrMousePatchVersion.supported` becomes `HerdrMousePatchCatalog.entries.map(\.version)`,
so recognised and patchable versions cannot drift apart. The version comes
from running `<binary> --version` (herdr prints exactly `herdr X`; the build
script checks this) through a version reader the app injects, with the child
environment from `ToolPath.childEnvironment()`, stdin from `/dev/null` and a
5 second deadline. `HerdrMousePatchVersion.parse` accepts only `herdr `
followed by dotted integers. A run that fails, times out or prints anything
else is an unknown version, which reads as `.unsupportedVersion`. The bytes
are never scanned for a version, since herdr embeds other version strings
(dependency paths, compatibility notes). Verb detection
(`terminal.mouse_capture`) is still a byte scan. The store's fingerprint check
keeps the reader to one run per binary change, and the post-download re-probe
and the update flow go through the same reader.

**Downloader** (`Sources/Flock/Herdr/HerdrMousePatchDownloader.swift`, with
its pure parts in FlockCore). Given an entry:

1. If `~/Library/Caches/<bundle id>/herdr-patches/<file>` exists and its
   SHA-256 matches, use it.
2. Otherwise download to a temp file in that directory through an injected
   transport (`URLSession` in the app), reporting progress.
3. Hash with CryptoKit. On mismatch, delete and fail with
   `checksumMismatch`. Nothing outside the cache directory is touched before
   the hash passes.
4. Move the verified file to the cache name and return its path.

**Install.** `HerdrMousePatchInstaller.install(artifactPath:binaryPath:)` runs
unchanged on the verified path: back up, stage, rename, verify verbs, roll back
on failure. Revert is unchanged.

**Row states.** `HerdrMousePatchDecision` keeps its shape; `artifactAvailable`
becomes "the catalog has this version". A herdr whose version is not in the
catalog, or could not be read, is `.unsupportedVersion`: usually a herdr newer
than this flock knows. The store gains a `downloading(progress)` phase between
confirming and installing.

| Situation | Row says |
| --- | --- |
| no patch for this version | "No mouse patch for herdr X yet. A flock update will add one." |
| downloading | "Downloading..." with progress; Install disabled |
| offline / HTTP error | "Couldn't download the patch. Check your connection and try again." |
| checksum mismatch | "The download didn't match what flock expected. Nothing was changed." |

The banner offer (`HerdrMousePatchOffer`) still offers only `.patchable`.

## 3. herdr update note

herdr's API does not expose its "update available" state; it lives in the TUI
only. flock reads the same source herdr does: `version` from
`https://herdr.dev/latest.json`.

**Check** (`HerdrUpdateCheck`). Fetches through an injected source when
Settings opens and when the app becomes active, at most once an hour. Any
failure (offline, bad JSON, missing field) yields "unknown" and hides
everything. No retries, no error UI.

**Decision** (pure, FlockCore). Inputs: installed version, latest version,
whether flock's patch is installed (`.installed` row state), whether the
catalog has the latest version, whether herdr is Homebrew-managed. Output:

| Case | Result |
| --- | --- |
| latest unknown, or latest <= installed (includes preview builds) | hidden |
| patch not installed | plain note |
| patch installed, catalog has latest | plain note + reinstall line |
| patch installed, catalog lacks latest | warning |

Homebrew-managed (binary path resolves under a Homebrew prefix's `Cellar`)
swaps the command for `brew upgrade herdr`, since `herdr update` refuses to
run there. Versions compare numerically by dotted components.

**Settings copy.** On the herdr tab, above the mouse patch row.

Plain note:

```text
herdr 0.9.6 is available (you have 0.9.5)
  Update without closing your panes:
    herdr update --handoff                         [Copy]
  Updating removes the mouse patch; reinstall it here afterwards.   <- only if installed
```

Warning (orange warning style, warning first):

```text
⚠ Updating herdr to 0.9.6 will turn off mouse support in flock
  flock doesn't have a mouse patch for 0.9.6 yet. Mouse clicks and
  scrolling in panes stop working until a flock update adds one.
  If you update anyway:  herdr update --handoff        [Copy]
```

`--handoff` is safe to recommend: the patch is client-side only, so the
handed-off server needs nothing from flock, and installing the new version's
patch afterwards never touches the server either.

**Title bar pill.** flock's window has no Settings button, so the signal is a
small pill in the title bar, beside where Flock Dev's "New build · Restart"
pill sits: `herdr 0.9.6` with an up-arrow glyph in a neutral capsule for the
plain note, and with a warning glyph in an orange capsule for the warning.
Clicking it opens Settings on the herdr tab (`SettingsTab.herdr`). It shows
exactly when the note does and has no dismiss of its own; it goes away when
herdr is updated.

## 3a. flock runs the update (added after the live run)

Running the command by hand left two rough edges: the patch row kept saying
"On" because nothing re-checked herdr, and every pane went unresponsive
because `--handoff` starts a new server while flock's bridges still point at
the old one. So flock runs the update itself and sequences what follows.

- The note and the warning gain an **Update herdr** button. The copyable
  command stays beneath it as a fallback. Homebrew installs keep the
  copy-only `brew upgrade herdr` line and no button.
- One confirmation, every time: title "Update herdr to X?", message "flock
  runs herdr update --handoff. Your panes keep running; Flock restarts
  afterwards to reconnect them." In the warning case the message adds "Mouse
  support turns off until a flock update adds a patch for X."
- flock runs `<resolved herdr> update --handoff` with
  `ToolPath.childEnvironment()`. While it runs, the section shows
  "Updating herdr..." with a spinner and the pill reads "Updating herdr".
  A non-zero exit shows "herdr couldn't update: <last line of its output>"
  in the section; nothing else changes.
- On success the patch store refreshes. If flock's patch was installed and
  the catalog has the new version, flock downloads, verifies and installs it
  straight away with no second confirmation (the update confirmation already
  said so: the plain note's reinstall line is the promise).
- Then one restart prompt, reusing the mouse patch restart banner:
  "herdr is updated" (or "herdr is updated and mouse support reinstalled"),
  "Restart Flock so your panes reconnect.", action "Restart Flock".
- The patch row re-checks herdr whenever the app becomes active and whenever
  the connected server's `herdrVersion` changes, so a hand-run update no
  longer leaves it stale.
- A confirmation is presented only by the surface that asked for it (banner
  or Settings row), never both.

## 3b. What a handoff must not cost (found in the live run)

A handoff keeps pane ids, stored tab and pane names, and Claude session ids,
but gives every pane a new `terminal_id` and stops reporting an idle pane's
terminal title until the title text changes (a herdr bug). Now that flock
runs the handoff, flock covers both:

- **Tab titles.** flock remembers the last non-empty terminal title per
  Claude session id, persisted across launches (bounded, most recent 200),
  and a pane with no title shows the remembered one before falling back to
  "shell". A title herdr reports always wins and refreshes the memory.
- **rt links.** flock's rt run and runner links also record the pane's
  public id. When a linked terminal id is gone, a link whose recorded pane
  still exists is kept and relabelled with the new terminal id instead of
  being torn down. Old labels without a pane id behave as before.

## 4. Testing

All hermetic: no network, no herdr, no real binaries.

- **Catalog:** every entry has an https URL and a 64-char lowercase hex
  SHA-256; versions are unique; every version from 0.9.1 to the newest entry is
  present with no gaps in the patch component.
- **Checksum and downloader:** small temp files through an injected transport:
  success, cached hit, cached file with a wrong hash re-downloads, mismatch
  deletes and fails, transport error, HTTP non-2xx.
- **Version reader:** parsing rejects anything but `herdr ` and dotted
  integers; a reader failure is unsupported; a 0.9.6 whose bytes mention
  0.9.5 is unsupported. Store tests inject a reader and never run a binary.
- **Row decision:** existing matrix tests, with `.unsupportedVersion` for a
  version the catalog lacks.
- **Update decision:** every row of the table above, plus Homebrew, a preview
  build newer than latest, and multi-digit components (0.9.10 > 0.9.9).
- **Render:** the herdr Settings tab with the plain note, the warning and the
  downloading state (`FLOCK_SETTINGS_RENDER_DIR`), and the title bar with no
  pill, the neutral pill and the orange pill (`FLOCK_CHROME_RENDER_DIR`), each
  in dark and light, and looked at.

## Rollout

1. Patch files and the new build script.
2. `publish-herdr-patch.sh`; build all five and publish `herdr-patch-0.9.1`
   through `herdr-patch-0.9.5`. Matt approves before anything is published.
3. Catalog, downloader, row changes; stop bundling.
4. Update check, note, warning and title bar pill.
5. End to end in Flock Dev: download-install the 0.9.5 patch over a stock
   0.9.5, revert, and show the note and warning with a faked latest version.

## Out of scope

- x86_64 patches.
- Running `brew upgrade herdr` from flock.
- A remote or signed catalog.
- Retiring old patch versions.
