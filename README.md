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

See `THIRD-PARTY-NOTICES.md` for the licenses of vendored and derived
third-party components.
