# Packaging

`Scripts/release-build.sh` builds the signed release bundle. See `README.md` for
how to run it.

The bundle is single-architecture (arm64), because `Vendor/GhosttyKit.xcframework`
is built native-only and a universal Release fails to link.

## What a stranger sees on first launch

Checked 2026-09-21 on a clean VM that had never seen this app or this
Developer ID: `mattstack-golden-26`, Gatekeeper on, no brew, no CLT, nothing
preinstalled. Driven by `rt-tray/vm/run/gatekeeper-check.sh` in repo-tools.

**flock clears Gatekeeper.** No "cannot be opened because the developer
cannot be verified", which is the outcome that would actually stop someone.
Notarization and stapling are honoured on a machine with no prior trust.

**One confirmation still appears**, the "downloaded from the Internet, are
you sure you want to open it?" prompt. That is normal for every notarized app
distributed outside the App Store and there is no way to remove it short of
shipping through the store. Do not read a report of it as a defect.

An admin password prompt also appeared, but that belongs to the harness
rather than to flock: it copies into `/Applications` as a standard user.
`--dest /Users/tester/Applications` avoids it, and Gatekeeper assesses the
same either way.

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
