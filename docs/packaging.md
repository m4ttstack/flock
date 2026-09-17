# Packaging

`Scripts/release-build.sh` builds the signed release bundle. See `README.md` for
how to run it.

The bundle is single-architecture (arm64), because `Vendor/GhosttyKit.xcframework`
is built native-only and a universal Release fails to link.

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
