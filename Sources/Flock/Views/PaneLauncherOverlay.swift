import FlockCore
import os
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
    /// The monogram's face when the default does not suit its glyphs.
    var monogramFont: Font? = nil
    var paletteName: String? = nil
    var paletteHint: String? = nil
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
            monogramColor: .init(red: 0.82, green: 0.51, blue: 0.31), mark: .claude,
            paletteName: "Claude", paletteHint: "Launch Claude Code CLI"
        ),
        HarnessEntry(
            id: "codex", binary: "codex", displayName: "codex", monogram: "X",
            monogramColor: .init(red: 0.29, green: 0.56, blue: 0.86), mark: .codex,
            paletteName: "Codex", paletteHint: "Launch Codex CLI"
        ),
    ]

    /// A fresh directory scan each call (cheap: one `isExecutableFile` per
    /// candidate directory) rather than a cached result, so a harness
    /// installed mid-session shows up the next time a launcher pane is
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
    /// `--repo` opens the picker across every repo even from inside one: a
    /// pane offering the launcher is already in its folder, so the pick is
    /// somewhere else.
    static let command = "rt cd --repo"
    static let title = "rt cd"

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
        entry.id == NavigatorRoster.rtCd.id ? NavigatorRoster.title : "Launch \(entry.displayName)"
    }

    private static let log = Logger(subsystem: "dev.mattstack.flock", category: "launcher")

    @MainActor
    static func target(on viewModel: SessionViewModel) -> PaneID? {
        let pane = viewModel.shownFocusedPaneID
        return LaunchTarget.pane(canvasPane: pane, agent: pane.flatMap { viewModel.model?.panes[$0]?.agent })
    }

    /// A click on the overlay's button, a ⌘ digit, a mouse pick from the
    /// Launch menu, or a palette row: the ways a launch starts, named in the
    /// log so a dead key can be told from a press herdr refused.
    enum LaunchPath: String {
        case click, key, menu, palette
    }

    /// Whether the menu action now running was fired by its key equivalent
    /// rather than picked with the mouse.
    @MainActor
    static var menuActionCameFromKey: Bool {
        NSApp.currentEvent?.type == .keyDown
    }

    /// A launch from the menu bar or a digit: into the shown empty pin when
    /// there is one, else the focused pane.
    @MainActor
    static func launch(_ entry: HarnessEntry, via path: LaunchPath, emptyPin: PinID?, on viewModel: SessionViewModel) async {
        if let emptyPin {
            await EmptyPinLaunch.start(emptyPin, with: entry, via: path, on: viewModel)
        } else {
            await launchInFocusedPane(entry, via: path, on: viewModel)
        }
    }

    /// A key press or menu pick flashes the item it fired; a click has
    /// already drawn its own press.
    @MainActor
    static func flash(_ entry: HarnessEntry, via path: LaunchPath, on target: SessionViewModel.LauncherFlashTarget, viewModel: SessionViewModel) {
        guard path != .click else { return }
        viewModel.flashLauncherSlot(entry.id, on: target)
    }

    /// ⌘1 and on, and the palette's rows: the pane is read as the key lands,
    /// never captured when the menu last rendered. Every press writes one log
    /// line, a press with no pane to launch in included.
    @MainActor
    static func launchInFocusedPane(_ entry: HarnessEntry, via path: LaunchPath, on viewModel: SessionViewModel) async {
        guard let pane = target(on: viewModel) else {
            log.notice("launch \(entry.id, privacy: .public) via \(path.rawValue, privacy: .public): no target")
            return
        }
        await launch(entry, in: pane, via: path, on: viewModel)
    }

    /// Every launch asks herdr whether the shell holds the pane's foreground
    /// as it fires: the overlay was shown on an answer that may be stale by
    /// the time of the click, and a command typed into anything but a shell
    /// at its prompt reaches that program as input.
    @MainActor
    static func launch(_ entry: HarnessEntry, in pane: PaneID, via path: LaunchPath, on viewModel: SessionViewModel) async {
        if viewModel.isLauncherShowing(pane) {
            flash(entry, via: path, on: .pane(pane), viewModel: viewModel)
        }
        let atPrompt = await viewModel.isAtPrompt(pane)
        log.notice(
            "launch \(entry.id, privacy: .public) via \(path.rawValue, privacy: .public) in \(pane.rawValue, privacy: .public): at prompt \(atPrompt)"
        )
        guard atPrompt else { return NSSound.beep() }
        if entry.id == NavigatorRoster.rtCd.id {
            await viewModel.launchNavigator(NavigatorRoster.command, in: pane)
        } else {
            await viewModel.launchHarness(entry.binary, in: pane)
        }
    }
}

/// Renders on a pane showing the launcher: one frosted bar holding the
/// navigator when there is one and an item per detected harness, centered
/// below the rows the screen holds when it fits there and over them when it
/// does not, and, only when a PATH resolved no harness at all, a dim line
/// directly below it saying so (`LauncherHint`), rather than leaving an empty
/// bar to be read as a pane with nothing to offer.
///
/// The items are the only thing here that answers the pointer: the bar's
/// ground, its padding and the gaps between items opt out, as does the hint,
/// which leaves every other click reaching the terminal underneath
/// (plain-click-to-focus, or typing). `PaneLauncherOverlayTests` asserts both
/// halves of that by hit-testing the real view.
struct PaneLauncherOverlay: View {
    let theme: Theme
    let entries: [HarnessEntry]
    let navigator: HarnessEntry?
    /// The rows the screen holds, which the bar sits below when it can.
    let occupiedRows: Int
    /// One terminal row in points; nil before the surface knows its cell size.
    let cellHeight: CGFloat?
    /// The slot a key press just fired, drawn pressed.
    var flashedSlot: String? = nil
    let onLaunch: (HarnessEntry) -> Void

    /// One row of breathing room below whatever the screen holds, and never
    /// less than the fixed clearance a fresh pane gets before its cell size is
    /// known.
    static func promptClearance(occupiedRows: Int, cellHeight: CGFloat?) -> CGFloat {
        let floor = ChromeMetrics.Launcher.promptClearance
        guard let cellHeight, cellHeight > 0, occupiedRows > 0 else { return floor }
        return max(floor, CGFloat(occupiedRows + 1) * cellHeight)
    }

    /// The bar's top edge, at the optical center (`barRise`) of the space below
    /// the prompt when the bar and a `barMargin` either side fit there;
    /// otherwise of the whole pane, where its blur covers the text behind it:
    /// a startup banner
    /// can be taller than the pane, and a bar pushed off the pane cannot be
    /// clicked.
    static func barTop(clearance: CGFloat, availableHeight: CGFloat, barHeight: CGFloat) -> CGFloat {
        let rise = ChromeMetrics.Launcher.barRise
        let below = availableHeight - clearance
        guard below >= barHeight + 2 * ChromeMetrics.Launcher.barMargin else {
            return max(0, (availableHeight - barHeight) * rise)
        }
        return clearance + max(ChromeMetrics.Launcher.barMargin, (below - barHeight) * rise)
    }

    var body: some View {
        GeometryReader { geometry in
            content.padding(.top, Self.barTop(
                clearance: Self.promptClearance(occupiedRows: occupiedRows, cellHeight: cellHeight),
                availableHeight: geometry.size.height, barHeight: ChromeMetrics.Launcher.barHeight
            ))
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }

    private var content: some View {
        let style = LauncherBarStyle(theme: theme)
        let slots = LauncherSlots.ordered(navigator: navigator, entries: entries)
        return VStack(spacing: ChromeMetrics.Launcher.hintSpacing) {
            if !slots.isEmpty {
                // A narrow pane drops the key hints before it would wrap a
                // harness name or push the bar past its edges.
                ViewThatFits(in: .horizontal) {
                    LauncherBar(style: style, slots: slots, showsShortcuts: true, flashedSlot: flashedSlot, onLaunch: onLaunch)
                    LauncherBar(style: style, slots: slots, showsShortcuts: false, flashedSlot: flashedSlot, onLaunch: onLaunch)
                }
                .padding(.horizontal, ChromeMetrics.Launcher.barSideMargin)
            }
            if let hint = LauncherHint.text(detected: entries.map(\.binary), searched: HarnessRoster.known.map(\.binary)) {
                Text(hint)
                    .font(ChromeType.launcherHint)
                    .foregroundStyle(style.keyHint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ChromeMetrics.Launcher.hintHorizontalPadding)
                    // Hit testing is off per drawn element, never on the stack
                    // around them: a disabled ancestor takes its whole subtree
                    // out of hit testing, and a descendant cannot opt back in.
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The bar's colors for one theme, dark or light as the rest of the chrome
/// decides it: by the luminance of the theme's panel.
struct LauncherBarStyle: Equatable {
    private typealias M = ChromeMetrics.Launcher

    let isDark: Bool
    let label: Color

    init(theme: Theme) {
        isDark = !ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        label = isDark ? Color(M.darkLabel) : theme.textStrong
    }

    var tint: Color {
        isDark ? Color(M.darkTint).opacity(M.darkTintOpacity) : Color.white.opacity(M.lightTintOpacity)
    }

    var keyHint: Color {
        isDark ? Color.white.opacity(M.darkKeyHintOpacity) : Color.black.opacity(M.lightKeyHintOpacity)
    }

    var innerStroke: Color {
        isDark ? Color.white.opacity(M.darkInnerStrokeOpacity) : Color.black.opacity(M.lightInnerStrokeOpacity)
    }

    var hairlineShadow: Color {
        Color.black.opacity(isDark ? M.darkHairlineShadowOpacity : M.lightHairlineShadowOpacity)
    }

    var dropShadow: Color {
        Color.black.opacity(isDark ? M.darkDropShadowOpacity : M.lightDropShadowOpacity)
    }

    /// No fill at rest; a press lights an item whether or not a hover was
    /// recorded first, since a click can land as the bar appears under a
    /// stationary pointer.
    func itemFill(isHovering: Bool, isPressed: Bool) -> Color {
        let ink = isDark ? Color.white : Color.black
        if isPressed { return ink.opacity(isDark ? M.darkPressedFill : M.lightPressedFill) }
        if isHovering { return ink.opacity(isDark ? M.darkHoverFill : M.lightHoverFill) }
        return .clear
    }
}

/// The frosted bar alone, shared by a pane's launcher and an empty pin's.
/// `leading` is an item ahead of the numbered slots with its own key hint.
struct LauncherBar: View {
    let style: LauncherBarStyle
    let slots: [HarnessEntry]
    let showsShortcuts: Bool
    var flashedSlot: String? = nil
    var leading: (entry: HarnessEntry, shortcut: String)? = nil
    let onLaunch: (HarnessEntry) -> Void

    var body: some View {
        HStack(spacing: ChromeMetrics.Launcher.itemSpacing) {
            if let leading {
                LauncherItem(
                    style: style, entry: leading.entry, shortcut: showsShortcuts ? leading.shortcut : nil,
                    isFlashed: flashedSlot == leading.entry.id
                ) {
                    onLaunch(leading.entry)
                }
            }
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, entry in
                LauncherItem(
                    style: style, entry: entry, shortcut: showsShortcuts ? LauncherSlots.shortcutLabel(at: index) : nil,
                    isFlashed: flashedSlot == entry.id
                ) {
                    onLaunch(entry)
                }
            }
        }
        .padding(ChromeMetrics.Launcher.barPadding)
        .background { LauncherBarGround(style: style).allowsHitTesting(false) }
    }
}

/// Blur, tint, inner stroke and the two outer shadows. The shadows are cast
/// by an opaque copy of the shape with its interior then cut away: a shadow
/// cast by the translucent tint would be as faint as the tint, and one left
/// under the bar would darken what the blur samples.
private struct LauncherBarGround: View {
    let style: LauncherBarStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.Launcher.barCornerRadius, style: .continuous)
        ZStack {
            ZStack {
                shape.fill(Color.black)
                    .shadow(color: style.hairlineShadow, radius: ChromeMetrics.Launcher.hairlineShadowRadius)
                shape.fill(Color.black)
                    .shadow(
                        color: style.dropShadow, radius: ChromeMetrics.Launcher.dropShadowRadius,
                        y: ChromeMetrics.Launcher.dropShadowY
                    )
            }
            .mask {
                Rectangle()
                    .padding(-ChromeMetrics.Launcher.shadowReach)
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            }
            LauncherBlur(isDark: style.isDark, cornerRadius: ChromeMetrics.Launcher.barCornerRadius)
                .clipShape(shape)
            shape.fill(style.tint)
            shape.strokeBorder(style.innerStroke, lineWidth: 1)
        }
    }
}

/// A behind-window blur would show the desktop; within-window blends what the
/// window itself draws behind the bar, which is the pane's terminal surface.
private struct LauncherBlur: NSViewRepresentable {
    let isDark: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> PassThroughEffectView {
        let view = PassThroughEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: PassThroughEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.layer?.cornerRadius = cornerRadius
    }
}

/// An `NSView` answers hit tests over its whole frame, which SwiftUI's
/// `allowsHitTesting` does not reach; this one never does, so the bar's
/// padding and the gaps between its items reach the terminal.
private final class PassThroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One slot's item. `isHovering` is held here rather than lifted to the bar
/// so each item answers only for the pointer being over ITSELF; a bar-level
/// hover lights every item at once.
private struct LauncherItem: View {
    let style: LauncherBarStyle
    let entry: HarnessEntry
    let shortcut: String?
    let isFlashed: Bool
    let onLaunch: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: ChromeMetrics.Launcher.itemContentSpacing) {
                HarnessBadge(entry: entry)
                Text(entry.displayName)
                    .font(ChromeType.launcherName)
                    .foregroundStyle(style.label)
                    .lineLimit(1)
                    .fixedSize()
                if let shortcut {
                    Text(shortcut)
                        .font(ChromeType.launcherShortcut)
                        .foregroundStyle(style.keyHint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(LauncherItemStyle(style: style, isHovering: isHovering, isFlashed: isFlashed))
        .onHover { hovering in
            withAnimation(.easeOut(duration: ChromeMetrics.Launcher.hoverFade)) { isHovering = hovering }
        }
        .accessibilityIdentifier("flock.pane.launcher.\(entry.binary)")
    }
}

/// `ButtonStyle.Configuration` cannot be built by a test, so each state's
/// fill is resolved by `LauncherBarStyle.itemFill`, where a test can assert
/// that rest, hover and press differ.
private struct LauncherItemStyle: ButtonStyle {
    let style: LauncherBarStyle
    let isHovering: Bool
    let isFlashed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed || isFlashed
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.Launcher.itemCornerRadius, style: .continuous)
        return configuration.label
            .padding(.vertical, ChromeMetrics.Launcher.itemVerticalPadding)
            .padding(.leading, ChromeMetrics.Launcher.itemLeadingPadding)
            .padding(.trailing, ChromeMetrics.Launcher.itemTrailingPadding)
            .background(shape.fill(style.itemFill(isHovering: isHovering, isPressed: isPressed)))
            // With no fill at rest, only the glyphs would take a click.
            .contentShape(shape)
            // Only the press animates here; the hover fade is driven from the
            // `onHover` that owns `isHovering`, since a ButtonStyle cannot see
            // that change coming.
            .animation(.easeOut(duration: ChromeMetrics.Launcher.hoverFade), value: isPressed)
    }
}

/// The vendor's mark where there is one, the monogram where there is not.
private struct HarnessBadge: View {
    let entry: HarnessEntry

    var body: some View {
        if let mark = entry.mark, mark.cgPath != nil {
            Circle()
                .fill(Color(mark.ground))
                .frame(width: ChromeMetrics.Launcher.logo, height: ChromeMetrics.Launcher.logo)
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
            .frame(width: ChromeMetrics.Launcher.logo, height: ChromeMetrics.Launcher.logo)
            .overlay {
                Text(entry.monogram)
                    .font(entry.monogramFont ?? ChromeType.launcherMonogram)
                    .foregroundStyle(entry.monogramInk)
            }
    }
}
