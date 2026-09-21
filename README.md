# Flock

A macOS terminal workspace app driven by herdr.

## Build

Generate the Xcode project (never hand-edit `Flock.xcodeproj`, it is
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

Builds `build/release/Flock.app` in the Release configuration with the
hardened runtime, then verifies it with `codesign` and `spctl`. It signs with
the machine's sole `Developer ID Application` identity when there is exactly
one; `--identity <name>` names a different one and `--adhoc` forces an ad-hoc
signature, which is what a machine with no Developer ID gets.

This script is the only path that produces a Developer ID signature. Xcode's
Product > Archive also builds Release now, but it uses the configuration's own
`CODE_SIGN_IDENTITY`, which is ad-hoc: an archive made that way looks like a
release artifact and is signed by nobody.

With a Developer ID signature, the script also submits the bundle for
notarization (`xcrun notarytool submit --wait`, keychain profile
`flock-notary` by default) and staples the ticket on success, so the
distributed artifact passes `spctl -a -vv` (`accepted` /
`source=Notarized Developer ID`) on a machine with no prior trust of this
Developer ID. An ad-hoc build is never a notarization candidate (Apple
requires Developer ID) and `spctl` rejecting it is expected, not a failure.
A Developer ID build with no notarization credential configured skips
notarization with setup instructions rather than failing, since the
signed artifact it already produced is real. See `--help` for the
credential and `--skip-notarize`/`--skip-verify` flags.

The bundle is single-architecture: `Vendor/GhosttyKit.xcframework` is built
for the architecture of the machine that ran `Scripts/libghostty.sh`, so
there is no second slice to link.

See `THIRD-PARTY-NOTICES.md` for the licenses of vendored and derived
third-party components.

## Dev build

```bash
Scripts/dev-build.sh
```

Builds `build/dev/Flock-dev.app`: same sources, ad-hoc signed, distinct
bundle id (`dev.mattstack.Flock.dev` vs the release build's
`dev.mattstack.Flock`) and product name, so it installs and runs side by
side with a release Flock.app without either shadowing the other. The
point is to rebuild and re-test without a `/Applications` install in the
way: rerun the script after an edit and reopen the same
`build/dev/Flock-dev.app` path. Never notarized, never meant to leave this
machine.
