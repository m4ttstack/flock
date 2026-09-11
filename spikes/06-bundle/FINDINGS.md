# Spike 06: Nested helper launch without a Gatekeeper prompt

Two tiny apps built with plain `swiftc` (no Xcode project needed for a build
this small): `SpikeHost.app` (menu-bar stub, `LSUIElement=true`, driven by a
command-line argument instead of a real menu so every launch path is
scriptable) nests `SpikeHelper.app` (a one-window SwiftUI app that writes a
launch marker file in `init()`, so a launch is provable without looking at a
screen). Everything lives under `build/` (gitignored, rebuilt from scratch by
`build.sh` every run). Signing identity: `Developer ID Application: Matthew
Goodwin (5BF66B3X4V)`, hardened runtime, signed inside-out (helper copies
first, host last, no `--deep`). **Not notarized** -- see "What requires
notarization" below.

## Verdict

**All three launch paths launched the helper silently, with no Gatekeeper
prompt, in both the clean and quarantined states, on this machine.**
Pass criterion from the brief ("at least one path launches silently with a
working windowed app") is met by all three, not just one. The three differ
instead on packaging constraints, bundle-path stability, and TCC identity --
see the table below and "Recommendation."

## Per-path table

| Path | Prompt | Silent launch | Distinct TCC identity | Dock/menu bar | Notes |
| --- | --- | --- | --- | --- | --- |
| (a) `NSWorkspace.openApplication` | No (clean or quarantined) | Yes | Yes (own `CFBundleIdentifier`, confirmed via `lsappinfo`) | Own Dock icon (LSUIElement=false in helper's Info.plist; not altered by launch path) | **Quarantined only:** helper is App-Translocated -- `Bundle.main.bundlePath` reported the helper running from `/private/var/folders/.../AppTranslocation/<uuid>/d/SpikeHost.app/Contents/Helpers/SpikeHelper.app`, not its real path. Any code that assumes its own bundle path is stable (relative resource lookups, `Contents/Helpers/` re-derivation) would break under this path when quarantined. |
| (b) `SMAppService.loginItem(identifier:)` | No (clean or quarantined) | Yes | Yes (own `CFBundleIdentifier`) | Own Dock icon (same Info.plist) | **Hard packaging constraint:** the helper must live at `Contents/Library/LoginItems/<Helper>.app` in the host bundle -- `Contents/Helpers/` is invisible to it. Confirmed empirically: registering against a copy of the host with only `Contents/Helpers/SpikeHelper.app` present fails with `SMAppServiceErrorDomain Code=22 "Invalid argument"`; the identical bundle under `Contents/Library/LoginItems/` registers and launches cleanly. `register()` on an already-logged-in user launches the item immediately, not just at next login (confirmed: marker file appears within ~2s of `register()` returning). No prompt observed registering a Developer-ID-signed, unnotarized login item on this machine, clean or quarantined. |
| (c) `Process` exec of the inner binary | No (clean or quarantined) | Yes | Yes (own `CFBundleIdentifier`, LaunchServices still registers it as a distinct running app even though it wasn't launched through LaunchServices) | Own Dock icon (same Info.plist) | Never translocated, quarantined or not -- raw `execve` never goes through the quarantine/LaunchServices machinery translocation depends on, so `Bundle.main.bundlePath` stays the real path in every state. This is the most predictable of the three for anything that cares about its own bundle path. |

All three register the launched process under its own `CFBundleIdentifier`
in LaunchServices (checked with `lsappinfo info -only bundleid,name,...`), so
TCC treats the helper as a separate app from the host regardless of which
mechanism launched it -- TCC identity comes from the code signature /
`CFBundleIdentifier`, not the launch path.

## Why no prompt, and the caveat that matters most

Given this machine's `spctl --status` reports `assessments enabled` (Gatekeeper
is not globally disabled) and System Integrity Protection is `enabled`, "no
prompt anywhere, even for a plain `open` of the quarantined host" was not the
expected result -- a fresh, unnotarized Developer-ID app downloaded and
double-clicked for the first time is generally expected to hit the hard
"Apple could not verify this app is free of malware" block post-Catalina.
Two explanations, not distinguished by this spike:

1. **Per-machine, per-signing-identity trust memory.** This machine has
   already had other apps built with this same Developer ID identity
   (`5BF66B3X4V`) run and (at some point) approved. Gatekeeper's first-launch
   assessment result may be cached per Team ID once a user has cleared it
   once for that developer on this machine, so subsequent apps signed by the
   same identity launch silently from then on. This is the most likely
   explanation and is a property of *this development machine's history*,
   not of the launch mechanism.
2. Some other machine-specific state (a prior `spctl` rule, a
   TCC/Gatekeeper database entry) not enumerated here.

**This is the single biggest thing that would need confirming on a genuinely
clean machine (or a notarized build) before trusting "no prompt" as a
property of the mechanism itself**, rather than of this machine's prior
history with this signing identity. See "What requires notarization."

### Quarantine flag correctness (a footgun worth flagging explicitly)

The first pass of this spike simulated quarantine with a flag value copied
from common online examples (`0081;...`). Cross-checking real quarantine
attributes already on this machine (`xattr -p com.apple.quarantine` over
`~/Downloads`) showed `0081` is what Chrome/Safari attach to inert data files
(images, PDFs) -- real `.app`/`.dmg` downloads on this machine carry `02c1`,
`0281`, `0283`, or `0183` instead. The comparison was re-run with `02c1`
(copied verbatim from a real downloaded, never-opened `.app` in
`~/Downloads`, not invented) recursively applied to every file in the host
bundle. Results were identical between the two flag values. Recorded here so
a future spike doesn't waste time re-discovering that the tutorial-common
`0081` value doesn't represent an executable download.

## codesign and spctl output

```
$ codesign -dv --verbose=4 build/SpikeHost.app
Identifier=com.mattstack.paddockspike.host
CodeDirectory v=20500 size=363 flags=0x10000(runtime) hashes=4+3 location=embedded
Authority=Developer ID Application: Matthew Goodwin (5BF66B3X4V)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=5BF66B3X4V
Runtime Version=26.5.0

$ codesign -dv --verbose=4 build/SpikeHost.app/Contents/Helpers/SpikeHelper.app
Identifier=com.mattstack.paddockspike.helper
CodeDirectory v=20500 size=365 flags=0x10000(runtime) hashes=4+3 location=embedded
Authority=Developer ID Application: Matthew Goodwin (5BF66B3X4V)
TeamIdentifier=5BF66B3X4V
Runtime Version=26.5.0

$ codesign -vvv --deep --strict build/SpikeHost.app
--validated:.../Contents/Library/LoginItems/SpikeHelper.app
--validated:.../Contents/Helpers/SpikeHelper.app
build/SpikeHost.app: valid on disk
build/SpikeHost.app: satisfies its Designated Requirement

$ spctl -a -vv build/SpikeHost.app
build/SpikeHost.app: rejected
source=Unnotarized Developer ID

$ spctl -a -vv build/SpikeHost.app/Contents/Helpers/SpikeHelper.app
build/SpikeHost.app/Contents/Helpers/SpikeHelper.app: rejected
source=Unnotarized Developer ID
```

`spctl -a -vv` rejects both bundles in every state tested (clean and
quarantined) -- expected and correct for an unnotarized Developer ID build,
and unrelated to the "no prompt observed at actual launch time" result above.
**`spctl`'s static assessment and the live launch behavior disagreed** in
this spike: `spctl` says "rejected," but every one of the six actual launch
attempts (3 paths x clean/quarantined) succeeded with no block and no
prompt. That gap is exactly the thing a notarized build (or a clean machine)
would resolve -- see below. Full transcripts: `build/comparison.log` is
regenerated by `run-comparison.sh` (not committed; rerun the script to
reproduce).

## What requires notarization (or a clean machine) to confirm

Not attempted here per the brief (no notarization credential handling in a
spike). These are the specific things this spike's un-notarized, single-dev-
machine result cannot settle:

- **Whether the "no prompt" result holds for a user who has never approved
  anything signed by this Developer ID before.** This is the load-bearing
  unknown -- see "per-machine trust memory" above. A notarized build (or a
  clean VM/fresh user account never exposed to this Team ID) is the only way
  to separate "this mechanism doesn't prompt" from "this machine already
  trusts this developer."
- Whether `spctl`'s static "rejected" verdict would flip to "accepted" for a
  notarized build of the same nest (expected: yes, that's the entire point
  of notarization), and whether that changes any of the three launch paths'
  live behavior (expected: no observable change for paths that already
  launch silently, but not verified).
- App Translocation's exact interaction with a notarized, Gatekeeper-approved
  app -- translocation is normally lifted once an app has been approved via
  Finder/LaunchServices from its installed location; whether that still
  applies to a nested helper opened via `NSWorkspace.openApplication` was not
  tested (would need a notarized build moved into `/Applications`-style
  installed location and opened via Finder once, then re-tested).

## Recommendation for the real Paddock tray-launch mechanism (feeds Task 32)

**Use `NSWorkspace.shared.openApplication(at:configuration:)` from
`Contents/Helpers/`, not `SMAppService` and not raw `Process` exec, with one
caveat to design around.**

- `SMAppService` is disqualified by its own rigidity: it mandates
  `Contents/Library/LoginItems/`, which is a different nesting convention
  than the rest of Paddock's helper packaging is presumably built around, and
  it frames the helper as a *login item* (auto-launch at login) rather than
  an on-demand tray launch -- the wrong semantic even where the location
  constraint is a non-issue. Reserve it only if Paddock later wants an actual
  "launch at login" feature, as a second, separate registration, not as the
  tray's launch mechanism.
- `Process` exec is the most "invisible" to Gatekeeper/quarantine machinery
  (no translocation, ever), which sounds attractive, but that invisibility is
  exactly the property that makes it look like a deliberate Gatekeeper
  bypass technique if ever reviewed or audited, and it forgoes
  `NSWorkspace`'s LaunchServices integration (proper foreground activation,
  window server handoff) for no observed benefit in this spike -- both paths
  launched silently.
- `NSWorkspace.openApplication` gets LaunchServices' normal handling (proper
  activation, Dock/window management) for free, plus the same TCC-distinct
  identity as the other two, and is the mechanism actually intended for
  "open this other app bundle" -- it also was the only path silent in the
  same run where `open` on the host itself was also silent, i.e. it matches
  how a user's own launch of the host would behave, rather than diverging
  from it.
- **Caveat to design around:** because this path translocates the helper
  under quarantine, do not have the helper (or the host, when locating the
  helper) resolve its own identity or resources from `Bundle.main.bundlePath`
  assuming it equals the on-disk install path -- resolve helper resources
  relative to a path handed in at launch (e.g. via `NSWorkspace.OpenConfiguration.arguments`
  or an environment variable) rather than assuming self-location, or the
  helper will silently read from a translocated read-only mirror the first
  time a freshly downloaded mattstack.app is run.
- Because this spike's biggest open question is whether "no prompt" holds
  once the signing identity is genuinely new to a machine, confirm this
  recommendation against a notarized build or a clean machine before Task 32
  ships it as final -- see "What requires notarization" above.

## Cleanup performed

- All `SpikeHelper`/`SpikeHost` processes launched during this spike were
  killed (`pkill -f`) after each check; `pgrep -fl SpikeHelper` /
  `SpikeHost` at the end of the spike returned nothing.
- The `SMAppService` login-item registration was unregistered after every
  register/status check; final `smappservice-status` reports
  `SMAppServiceStatus(rawValue: 0)` (not registered). Note: `sfltool
  dumpbtm` still lists a disabled historical entry for
  `com.mattstack.paddockspike.helper` -- this is normal macOS Background Task
  Management bookkeeping (System Settings > Login Items keeps a disabled row
  after unregistering rather than purging it immediately) and does not mean
  the item is active; there is no live registration.
- No installed/blessed app bundle (`/Applications/mattstack.app`,
  `rt-tray/mattstack-dev.app`) was touched. All build output lives under
  `spikes/06-bundle/build/` (gitignored) and scratch files under
  `/tmp/paddock-spike-06/` (removed at the end of the spike).

## Files

- `build.sh` -- builds both apps with `swiftc`, assembles the two bundles
  (`Contents/Helpers/SpikeHelper.app` and `Contents/Library/LoginItems/SpikeHelper.app`),
  signs inside-out with hardened runtime. Fully reproducible; `rm -rf build/`
  and rerun to get an identical result.
- `run-comparison.sh` -- drives all three launch paths in clean and
  quarantined states, dumps marker/result files, applies/removes the
  quarantine xattr, kills helpers and unregisters the login item between
  runs. Writes `build/comparison.log` (gitignored).
- `Sources/HostApp/main.swift` -- CLI-argument-driven host (menu-bar stub
  stand-in; a real menu wasn't built since the comparison is about the
  launch mechanism, not the menu UI).
- `Sources/SpikeHelper/SpikeHelperApp.swift` -- one-window SwiftUI helper
  that writes `/tmp/paddock-spike-06/helper-launched-<pid>.marker` in `init()`.
