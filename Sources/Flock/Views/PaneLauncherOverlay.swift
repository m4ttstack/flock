import FlockCore
import SwiftUI

/// One CLI agent harness `HarnessRoster` knows how to launch. `mark` is the
/// vendor's own published mark (see `Resources/HarnessMarks/README.md` for
/// each one's source and terms); an entry without one falls back to the
/// monogram badge, which is what keeps the roster extensible.
struct HarnessEntry: Identifiable, Equatable {
    let id: String
    let binary: String
    let displayName: String
    let monogram: String
    let monogramColor: Color
    var mark: HarnessMark?
    var monogramInk: Color = .white
}

/// Every harness flock knows how to offer, resolved at launcher-render time
/// against the PATH the app resolved at startup (`ToolPath`), never against
/// the one it was handed: a launch from Finder or from the tray inherits
/// launchd's PATH, which holds no agent CLI at all. Extend `known` to add one;
/// resolution alone decides what actually renders for a given machine.
enum HarnessRoster {
    static let known: [HarnessEntry] = [
        HarnessEntry(
            id: "claude", binary: "claude", displayName: "claude", monogram: "C",
            monogramColor: .init(red: 0.82, green: 0.51, blue: 0.31), mark: .claude
        ),
        HarnessEntry(
            id: "codex", binary: "codex", displayName: "codex", monogram: "X",
            monogramColor: .init(red: 0.29, green: 0.56, blue: 0.86), mark: .codex
        ),
    ]

    /// A fresh directory scan each call (cheap: one `isExecutableFile` per
    /// candidate directory) rather than a cached result, so a harness
    /// installed mid-session shows up the next time a pristine pane is
    /// created rather than only at process start.
    static func detected(pathEnvironment: String = ToolPath.resolved) -> [HarnessEntry] {
        known.filter { entry in
            UserPath.resolve(entry.binary, on: pathEnvironment) != nil
        }
    }
}

/// The directory picker the launcher offers ahead of the harnesses, since
/// picking a folder is the step before launching an agent in it. Offered only
/// where `rt` resolves on flock's startup PATH; the badge is rt's own pink on
/// its plum ground.
enum NavigatorRoster {
    static let command = "rt cd"

    static let rtCd = HarnessEntry(
        id: "rt-cd", binary: "rt", displayName: "cd", monogram: "rt",
        monogramColor: RtBrand.plum, monogramInk: RtBrand.pink
    )

    static func detected(pathEnvironment: String = ToolPath.resolved) -> HarnessEntry? {
        UserPath.resolve(rtCd.binary, on: pathEnvironment) == nil ? nil : rtCd
    }
}

/// The launcher's buttons in the order they draw, which is the order ⌘1, ⌘2
/// and on reach them: the navigator first, then each detected harness. A
/// number names a position, not a harness, so it moves when the row does.
enum LauncherSlots {
    static func ordered(navigator: HarnessEntry?, entries: [HarnessEntry]) -> [HarnessEntry] {
        Array(([navigator].compactMap { $0 } + entries).prefix(9))
    }

    static func current() -> [HarnessEntry] {
        ordered(navigator: NavigatorRoster.detected(), entries: HarnessRoster.detected())
    }

    static func key(at index: Int) -> KeyEquivalent {
        KeyEquivalent(Character(String(index + 1)))
    }

    static func shortcutLabel(at index: Int) -> String {
        ShortcutLabel.text(key: key(at: index), modifiers: .command)
    }

    static func title(for entry: HarnessEntry) -> String {
        entry.id == NavigatorRoster.rtCd.id ? NavigatorRoster.command : "Launch \(entry.displayName)"
    }

    @MainActor
    static func launch(_ entry: HarnessEntry, in pane: PaneID, on viewModel: SessionViewModel) async {
        if entry.id == NavigatorRoster.rtCd.id {
            await viewModel.launchNavigator(NavigatorRoster.command, in: pane)
        } else {
            await viewModel.launchHarness(entry.binary, in: pane)
        }
    }
}

/// Renders on a pristine flock-created pane: the bare shell prompt stays
/// visible above (this view never covers it -- it only occupies the space
/// below, via its own top spacer), the navigator when there is one and a
/// button per detected harness centered in that space, and, only when a PATH
/// resolved no harness at all, a dim line at the very bottom saying so
/// (`LauncherHint`), rather than leaving an empty button row to be read as a
/// pane with nothing to offer.
///
/// The buttons are the only thing here that answers the pointer: the spacers
/// draw nothing and so claim nothing, and the hint opts itself out, which
/// leaves every other click reaching the terminal underneath
/// (plain-click-to-focus, or typing). `PaneLauncherOverlayTests` asserts both
/// halves of that by hit-testing the real view.
struct PaneLauncherOverlay: View {
    let theme: Theme
    let entries: [HarnessEntry]
    let navigator: HarnessEntry?
    let onLaunch: (HarnessEntry) -> Void

    var body: some View {
        VStack(spacing: ChromeMetrics.Launcher.spacing) {
            Spacer(minLength: 0)
            // A narrow pane drops the shortcut hints before it would wrap a
            // harness name or push the row past its edges.
            ViewThatFits(in: .horizontal) {
                buttonRow(showsShortcuts: true)
                buttonRow(showsShortcuts: false)
            }
            Spacer(minLength: 0)
            if let hint = LauncherHint.text(detected: entries.map(\.binary), searched: HarnessRoster.known.map(\.binary)) {
                Text(hint)
                .font(ChromeType.launcherHint)
                .foregroundStyle(theme.textLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ChromeMetrics.Launcher.hintHorizontalPadding)
                .padding(.bottom, ChromeMetrics.Launcher.hintBottomPadding)
                // Hit testing is off per drawn element, never on the stack
                // around them: a disabled ancestor takes its whole subtree
                // out of hit testing, and a descendant cannot opt back in.
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, ChromeMetrics.Launcher.promptClearance)
    }

    private func buttonRow(showsShortcuts: Bool) -> some View {
        HStack(spacing: ChromeMetrics.Launcher.buttonSpacing) {
            let slots = LauncherSlots.ordered(navigator: navigator, entries: entries)
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, entry in
                LauncherButton(
                    theme: theme, entry: entry, shortcut: showsShortcuts ? LauncherSlots.shortcutLabel(at: index) : nil
                ) {
                    onLaunch(entry)
                }
            }
        }
    }
}

/// One harness's button. `isHovering` is held here rather than lifted to the
/// row so each button answers only for the pointer being over ITSELF; a row
/// -level hover lights both buttons at once.
private struct LauncherButton: View {
    let theme: Theme
    let entry: HarnessEntry
    let shortcut: String?
    let onLaunch: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: ChromeMetrics.Launcher.labelSpacing) {
                HarnessBadge(entry: entry)
                Text(entry.displayName)
                    .font(ChromeType.launcherName)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .fixedSize()
                if let shortcut {
                    Text(shortcut)
                        .font(ChromeType.launcherShortcut)
                        .foregroundStyle(theme.textLabel)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(LauncherButtonStyle(theme: theme, isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.easeOut(duration: ChromeMetrics.Launcher.hoverFade)) { isHovering = hovering }
        }
        .accessibilityIdentifier("flock.pane.launcher.\(entry.binary)")
    }
}

/// What a launcher button looks like in one of its three states. Split out of
/// the `ButtonStyle` because `ButtonStyle.Configuration` cannot be built by a
/// test, so a style that reads `isPressed` inline has no assertable press
/// state at all -- and "all three states look identical" is precisely the bug
/// this replaced.
struct LauncherButtonAppearance: Equatable {
    let fill: Color
    let border: Color
    let pressWash: Double
    let scale: CGFloat

    static func resolve(theme: Theme, isHovering: Bool, isPressed: Bool) -> LauncherButtonAppearance {
        let lit = isHovering || isPressed
        return LauncherButtonAppearance(
            fill: lit ? theme.selection : theme.tabRest,
            border: lit ? theme.accent.opacity(ChromeMetrics.Launcher.hoverBorderAccent) : theme.rule,
            pressWash: isPressed ? ChromeMetrics.Launcher.pressedAccent : 0,
            scale: isPressed ? ChromeMetrics.Launcher.pressedScale : 1
        )
    }
}

/// Rest, hover and press as three visibly different states. `.plain` shipped
/// here first, which draws all three identically: the button took a click and
/// gave nothing back, so it read as decoration rather than a control.
private struct LauncherButtonStyle: ButtonStyle {
    let theme: Theme
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let appearance = LauncherButtonAppearance.resolve(
            theme: theme, isHovering: isHovering, isPressed: configuration.isPressed
        )
        let shape = RoundedRectangle(cornerRadius: PaneChrome.cornerRadius)
        return configuration.label
            .padding(.horizontal, ChromeMetrics.Launcher.buttonHorizontalPadding)
            .padding(.vertical, ChromeMetrics.Launcher.buttonVerticalPadding)
            .background(
                shape
                    .fill(appearance.fill)
                    .overlay(shape.fill(theme.accent).opacity(appearance.pressWash))
            )
            .overlay(shape.strokeBorder(appearance.border, lineWidth: 1))
            .scaleEffect(appearance.scale)
            // Only the press animates here; the hover fade is driven from the
            // `onHover` that owns `isHovering`, since a ButtonStyle cannot see
            // that change coming.
            .animation(.easeOut(duration: ChromeMetrics.Launcher.hoverFade), value: configuration.isPressed)
    }
}

/// The vendor's mark where there is one, the monogram where there is not.
private struct HarnessBadge: View {
    let entry: HarnessEntry

    var body: some View {
        if let mark = entry.mark, mark.cgPath != nil {
            Circle()
                .fill(Color(mark.ground))
                .frame(width: ChromeMetrics.Launcher.monogram, height: ChromeMetrics.Launcher.monogram)
                .overlay(
                    MarkShape(mark: mark)
                        .fill(Color(mark.ink))
                        .padding(ChromeMetrics.Launcher.markInset)
                )
        } else {
            MonogramBadge(entry: entry)
        }
    }
}

/// Scales the mark to fit, centered, in whatever space it is given. The
/// decode happens here, per draw, rather than once into shared storage: a
/// `Shape` must be `Sendable`, so it cannot carry the decoded `CGPath`, and a
/// cache would be shared mutable state for a parse that costs microseconds.
private struct MarkShape: Shape {
    let mark: HarnessMark

    func path(in rect: CGRect) -> Path {
        guard let cgPath = mark.cgPath else { return Path() }
        // Fitted to the ink rather than to the document each mark was drawn
        // in: the two vendors leave very different margins inside their own
        // viewBox, so honoring those would render one mark at half the size
        // of the other. The badge's own inset gives every mark clear space.
        let ink = cgPath.boundingBoxOfPath
        guard ink.width > 0, ink.height > 0 else { return Path() }
        let scale = min(rect.width / ink.width, rect.height / ink.height)
        let size = CGSize(width: ink.width * scale, height: ink.height * scale)
        let transform = CGAffineTransform(
            translationX: rect.midX - size.width / 2, y: rect.midY - size.height / 2
        )
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -ink.minX, y: -ink.minY)
        return Path(cgPath).applying(transform)
    }
}

private struct MonogramBadge: View {
    let entry: HarnessEntry

    var body: some View {
        Circle()
            .fill(entry.monogramColor)
            .frame(width: ChromeMetrics.Launcher.monogram, height: ChromeMetrics.Launcher.monogram)
            .overlay(
                Text(entry.monogram)
                    .font(ChromeType.launcherMonogram)
                    .foregroundStyle(entry.monogramInk)
            )
    }
}
