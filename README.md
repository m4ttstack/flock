<div align="center">

<img src="Sources/Flock/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" height="128" alt="Flock app icon: a ram's head with three more stacked behind it">

# Flock

A native macOS window onto your [herdr](https://github.com/herdrdev/herdr) session.

[![Latest release](https://img.shields.io/github/v/release/m4ttstack/flock?label=download)](https://github.com/m4ttstack/flock/releases/latest)
[![Build and test](https://github.com/m4ttstack/flock/actions/workflows/tests.yml/badge.svg)](https://github.com/m4ttstack/flock/actions/workflows/tests.yml)

</div>

A Mac app for using herdr. Flock let's you drag and drop anything you see to move or rearrange. Also offers a workspaces view to re-arrange even across workspaces. Flock supports keyboard nav and improves how you interact with your herdr notifications, too.

Also includes:

- a workspace switcher inspired by MacOS CMD + Tab
- Themes
- Mouse mode toggles
- Command palette
- Quick start keys on a new pane

Uses [libghostty](https://github.com/ghostty-org/ghostty) under the hood.

Please excuse my dust, this project is in continual development as I refine things!

## Requirements

- macOS 15 or later on Apple silicon
- [herdr](https://github.com/herdrdev/herdr) 0.9 or later, on your `PATH`

## Installation

1. Download `Flock-<version>.dmg` from the
   [latest release](https://github.com/m4ttstack/flock/releases/latest).
2. Open it and drag **Flock** onto **Applications**.
3. Open Flock from Applications. It is signed and notarized by Apple, so macOS
   asks only its usual "downloaded from the Internet" question the first time.

From then on Flock checks for updates by itself and installs them quietly.
**Flock > Check for Updates…** checks right away.

## Quickstart

Start herdr the way you normally do, then open Flock. It attaches to your
default herdr session (`~/.config/herdr/herdr.sock`) and shows it straight
away. If herdr is not running, Flock offers a **Start herdr** button. To open
a different session, launch Flock with `HERDR_SOCKET_PATH` set:

```bash
HERDR_SOCKET_PATH=~/.config/herdr/sessions/work/herdr.sock open -a Flock
```

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd><kbd>T</kbd> | New tab in the current workspace |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd> | New workspace |
| <kbd>⌘</kbd><kbd>K</kbd> | Command palette |
| <kbd>⌃</kbd><kbd>Tab</kbd> | Workspace switcher (hold <kbd>⌃</kbd>, press <kbd>Tab</kbd> to step, let go to switch) |
| <kbd>⌃</kbd><kbd>⌘</kbd><kbd>←</kbd><kbd>→</kbd> | Previous / next tab |
| <kbd>⌘</kbd><kbd>1</kbd> <kbd>⌘</kbd><kbd>2</kbd> <kbd>⌘</kbd><kbd>3</kbd> | Press the focused pane's launcher buttons (rt cd, Claude, Codex) |
| <kbd>⌘</kbd><kbd>R</kbd> | Rearrange mode (<kbd>Esc</kbd> leaves it) |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> | All Workspaces |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd><kbd>→</kbd><kbd>↑</kbd><kbd>↓</kbd> | Focus the pane on that side |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd><kbd>→</kbd><kbd>↑</kbd><kbd>↓</kbd> | Move the focused pane that way |
| <kbd>⇧</kbd><kbd>⌃</kbd><kbd>⌘</kbd><kbd>←</kbd><kbd>→</kbd><kbd>↑</kbd><kbd>↓</kbd> | Swap the focused pane with its neighbor that way |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd>, or click a pane's mouse icon | Switch where the focused pane's plain right-clicks go: its program (the default) or the pane menu. The icon shows while the program has the mouse |
| <kbd>⌥</kbd> + right-click | Whichever of the two a plain right-click does not get |
| <kbd>F2</kbd> | Rename the selected workspace or tab |
| <kbd>⌘</kbd><kbd>Z</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd> | Undo / redo a move |
| <kbd>⌘</kbd><kbd>J</kbd> | Open the oldest notification |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd> | Clear notifications |
| <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>-</kbd> | Bigger / smaller text |
| <kbd>⌘</kbd><kbd>,</kbd> | Settings |

## Settings

- **Notifications > Show in sidebar:** *Until seen* (the default), *For 5
  seconds*, or *Never*. A question from an agent stays until you answer it.
- **Rearrange Mode > After a move:** turn rearrange mode off after a drag
  changes the layout (the default), or keep it on.
- **herdr > Mouse support:** herdr 0.9.1 does not pass clicks and scrolling
  through to its panes from a client like Flock. Flock carries a build of the
  same herdr version that does, and can install it for you, keeping your
  original to restore later.

## Works with rt

If you run agents with [rt](https://github.com/m4ttstack/rt), Flock picks up a
few extras by itself:

- Each pane gets an rt button that opens `rt nav`, `rt glitter`, `rt run` and
  `rt runner` in a modal over the tabs, starting in the pane's folder.
- A new pane offers rt cd next to the agents. In a pane running Claude Code,
  rt cd and rt nav type `/cd <path>` into Claude instead.
- Herds get their own sidebar section with progress read from rt, and the
  board app's workspaces fold into a Board section.
- rt chat is a click away, with its own Chat menu.

None of it is needed to use Flock with plain herdr.

## Building from source

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a few minutes for the first libghostty build.

```bash
git clone --recursive https://github.com/m4ttstack/flock.git
cd flock
Scripts/libghostty.sh     # builds Vendor/GhosttyKit.xcframework (fetches its own zig)
Scripts/fetch-sparkle.sh  # vendors the pinned Sparkle release
Scripts/build.sh          # xcodegen, then a Debug build
Scripts/run.sh
```

`Flock.xcodeproj` is generated from `project.yml`: edit that and rerun
`xcodegen`, never the project itself. `Scripts/dev-build.sh` builds a separate
`Flock-dev.app` with its own bundle id, so it runs side by side with an
installed Flock.

Run the tests and checks CI runs:

```bash
xcodebuild test -scheme Flock -destination 'platform=macOS' -only-testing:FlockCoreTests -skipPackagePluginValidation
xcodebuild test -scheme FlockChromeRender -destination 'platform=macOS' -skipPackagePluginValidation
Scripts/checks.sh
```

Signing, notarization, the disk image and releasing an update are covered in
[docs/packaging.md](docs/packaging.md).

## Contributing

Issues and pull requests are welcome. Before opening a pull request, run the
two test schemes and `Scripts/checks.sh` above; CI runs the same on every push.
Flock follows herdr rather than leading it, so a change that needs something
herdr does not expose yet is best raised with herdr first.

## License

Flock is under the [Business Source License 1.1](LICENSE): free to use,
including at work, as long as you do not offer it or a derivative as a
commercial terminal emulator, terminal multiplexer or remote-session client.
On 2030-09-20 it becomes MIT. Parts of Flock derive from
[Herdglass](https://github.com/buldezir/Herdglass), which carries the same
terms, and it builds on Ghostty, Sparkle and Inter.
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) has the details and every
license.
