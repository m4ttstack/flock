# Packaging

`Scripts/release-build.sh` builds the signed release bundle. See `README.md` for
how to run it.

The bundle is single-architecture (arm64), because `Vendor/GhosttyKit.xcframework`
is built native-only and a universal Release fails to link.

## What a stranger sees on first launch

Checked 2026-09-22 on a clean VM that had never seen this app or this
Developer ID: `mattstack-golden-26`, Gatekeeper on, no brew, no CLT, nothing
preinstalled. Driven by `rt-tray/vm/run/gatekeeper-check.sh` in repo-tools,
which ran unattended and passed all nine phases.

**flock clears Gatekeeper.** No "cannot be opened because the developer
cannot be verified", no "Apple could not verify this app is free of
malware". Notarization and stapling are honoured on a machine with no prior
trust.

That negative is worth something because the same run proves the check can
detect a refusal: it builds a deliberately unsigned app, launches it in the
same guest through the same probe, and requires a refusal to be seen and
classified before it will report anything about flock. Earlier versions of
this check could not have produced a refusal at all, and their clean results
meant nothing.

**One confirmation still appears**, the "downloaded from the Internet, are
you sure you want to open it?" prompt. That is normal for every notarized app
distributed outside the App Store and there is no way to remove it short of
shipping through the store. Do not read a report of it as a defect.

**A Documents (or Desktop, or Downloads) permission prompt is expected**, the
first time a pane's working directory lands in one of those folders. flock
hosts the terminal, so macOS attributes the access to flock; every terminal
emulator raises the same prompt. It is not a defect and there is nothing to
suppress.

It appears **once** for the distributed app and on **every launch** of a
local Debug build. TCC keys a grant to the code-signing identity, and a
Debug build is ad-hoc signed with no team, so each rebuild looks like a
different app and the previous grant does not apply. The release build
carries a stable Developer ID, so the grant survives launches and updates
alike. A report of "it asks every time" from a developer is this, not a bug.
Untested on a clean machine: the clean-room golden has no herdr, so flock
never reaches a pane and never asks.

**flock launched App-Translocated**, from a read-only copy under
`/private/var/.../AppTranslocation/` rather than from `/Applications`. macOS
does this to a quarantined app that the user has not explicitly moved itself,
and answering the open prompt comes too late to prevent it for that launch.
It matters here because `Sources/Flock/Ghostty/GhosttyControlSurfaceFactory.swift`
is the one place flock resolves its own bundle path, and under translocation
that path is a temporary read-only copy. **Whether that breaks anything is
untested**: the golden has no herdr, so flock never got past its no-herdr
screen. A real user who drags the app to Applications themselves makes a
gesture the harness cannot reproduce over Apple Events, so their first launch
may well not translocate.

**What this did NOT prove.** That flock works. The golden has no herdr, so
the app opened onto its own no-herdr screen and nothing else was exercised.
The run is a launch check and a signature check, not a smoke test.

## Shipping flock inside mattstack.app

The tray and bundle-pipeline work lives in `repo-tools` and is tracked in
[MAT-418](https://linear.app/mattstack/issue/MAT-418/embed-flockapp-in-mattstackapp-and-add-a-tray-launch-item),
which carries the file-by-file changes, the signing order that keeps the nested
bundle's seal intact, and what the MR has to verify.

Two constraints from that research are worth knowing before touching signing
here: an already-signed Flock needs no re-sign when nested (only the outer
bundle's seal has to be restored), and flock has exactly one place that
resolves its own path, `Sources/Flock/Ghostty/GhosttyControlSurfaceFactory.swift`,
which is what App Translocation would relocate.
