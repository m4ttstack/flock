# Paddock

A macOS terminal workspace app driven by herdr.

## Build

Generate the Xcode project (never hand-edit `Paddock.xcodeproj`, it is
generated from `project.yml`):

```bash
xcodegen
```

Before the first build, vendor libghostty:

```bash
git submodule update --init Vendor/ghostty
./Scripts/libghostty.sh
```

That takes a while, it compiles ghostty with `-Doptimize=ReleaseFast`, and
leaves `Vendor/GhosttyKit.xcframework` plus a `Vendor/libghostty.version` note
of what it was built from. Neither is in git; the pin is the `Vendor/ghostty`
gitlink, and those two are what your machine made of it.
`Scripts/libghostty.sh --check` reports whether the built artifact still
matches the pin.

Then build and run:

```bash
Scripts/build.sh
Scripts/run.sh
```

## Release build

```bash
Scripts/release-build.sh
```

Builds `build/release/Paddock.app` in the Release configuration with the
hardened runtime, then verifies it with `codesign` and `spctl`. It signs with
the machine's sole `Developer ID Application` identity when there is exactly
one; `--identity <name>` names a different one and `--adhoc` forces an ad-hoc
signature, which is what a machine with no Developer ID gets.

Nothing here notarizes, so `spctl -a -vv` reports `rejected` /
`source=Unnotarized Developer ID` on every build the script makes. That is
the expected outcome, not a failure, and the script says so rather than
exiting non-zero on it.

The bundle is single-architecture: `Vendor/GhosttyKit.xcframework` is built
for the architecture of the machine that ran `Scripts/libghostty.sh`, so
there is no second slice to link.

See `THIRD-PARTY-NOTICES.md` for the licenses of vendored and derived
third-party components.
