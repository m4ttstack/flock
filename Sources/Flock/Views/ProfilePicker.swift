import AppKit
import FlockCore
import SwiftUI

/// What the profile picker and the Flock > Profile menu share: the profiles,
/// the switch, the way to Settings, and whether the list is open. The
/// shortcut opens the list only while a picker is on screen to anchor it and
/// its window is key, so it never pops up behind Settings.
@MainActor
@Observable
final class ProfilePickerContext {
    static let shortcutKey: KeyEquivalent = "p"
    static let shortcutModifiers: EventModifiers = [.control, .command]
    static var shortcut: KeyboardShortcut { KeyboardShortcut(shortcutKey, modifiers: shortcutModifiers) }
    static var shortcutLabel: String { ShortcutLabel.text(key: shortcutKey, modifiers: shortcutModifiers) }

    let profiles: ProfileStore
    let isLocked: Bool
    @ObservationIgnored private let switchProfile: (String) async -> Bool
    @ObservationIgnored private let listMachines: () async -> [HerdrMachine]?
    @ObservationIgnored private let keyWindow: () -> NSWindow?
    @ObservationIgnored weak var anchorWindow: NSWindow?

    var isOpen = false
    private var mounted = 0
    private var keyChanges = 0
    @ObservationIgnored private var keyObservers = NotificationObservers()

    init(
        profiles: ProfileStore, isLocked: Bool,
        switchProfile: @escaping (String) async -> Bool, listMachines: @escaping () async -> [HerdrMachine]?,
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }
    ) {
        self.profiles = profiles
        self.isLocked = isLocked
        self.switchProfile = switchProfile
        self.listMachines = listMachines
        self.keyWindow = keyWindow
        keyObservers.tokens = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanges += 1 }
            }
        }
    }

    var canOpen: Bool { mounted > 0 && !isLocked }

    /// What the menu item and shortcut need: a mounted picker whose window is
    /// key. Reading `keyChanges` is what re-evaluates the menu when another
    /// window takes key.
    var canOpenFromShortcut: Bool {
        _ = keyChanges
        return canOpen && anchorWindow != nil && keyWindow() === anchorWindow
    }

    /// A click lands in the picker's own window, so only the shortcut needs
    /// that window to be key.
    func open(fromClick: Bool = false) {
        guard fromClick ? canOpen : canOpenFromShortcut else { return }
        isOpen = true
    }

    func mount() { mounted += 1 }

    func unmount() {
        mounted = max(mounted - 1, 0)
        if mounted == 0 { isOpen = false }
    }

    /// A nil list means `herdr machine list` could not be read, which says
    /// nothing about which machines exist.
    func refreshMachines() async {
        if let machines = await listMachines() { profiles.syncMachines(machines) }
    }

    func choose(_ id: String) {
        isOpen = false
        guard id != profiles.currentID else { return }
        Task { _ = await switchProfile(id) }
    }

    func manage(opensNewProfile: Bool, selection: SettingsTabSelection?, openSettings: OpenSettingsAction) {
        isOpen = false
        selection?.tab = .profiles
        selection?.opensNewProfile = opensNewProfile
        openSettings()
    }
}

/// Removes its observers when the owner goes away.
private final class NotificationObservers {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// Reports the window a view lands in, for `ProfilePickerContext.anchorWindow`.
private struct WindowReporter: NSViewRepresentable {
    let report: (NSWindow?) -> Void

    final class Probe: NSView {
        var report: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.report = report
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.report = report
    }
}

extension ProfileConnectionDot {
    func color(in theme: Theme) -> Color {
        switch self {
        case .live: theme.green
        case .attention: theme.yellow
        }
    }
}

/// The top of the rail, and the same spot on a machine's connection screen:
/// the current profile, which opens the list of profiles and herdr machines
/// to switch to.
struct ProfilePicker: View {
    let theme: Theme
    @Bindable var context: ProfilePickerContext
    let currentDot: ProfileConnectionDot?
    var forced: ControlInteraction?

    @Environment(\.openSettings) private var openSettings
    @Environment(SettingsTabSelection.self) private var selection: SettingsTabSelection?
    @State private var isHovering = false

    private var model: ProfilePickerModel {
        ProfilePickerModel(profiles: context.profiles.profiles, currentID: context.profiles.currentID, currentDot: currentDot)
    }

    var body: some View {
        let current = model.current
        Button { context.open(fromClick: true) } label: {
            ProfilePickerLabel(
                theme: theme, title: current?.title ?? context.profiles.current.name,
                isMachine: current?.isMachine ?? false, dot: current?.dot, showsChevron: !context.isLocked,
                interaction: forced ?? ControlInteraction(isHovering: isHovering, isPressed: context.isOpen)
            )
        }
        .buttonStyle(.plain)
        .disabled(context.isLocked)
        .onHover { isHovering = $0 }
        .help(Self.tooltip(name: current?.title ?? context.profiles.current.name, isLocked: context.isLocked))
        .popover(isPresented: $context.isOpen, arrowEdge: .bottom) {
            ProfilePickerList(
                theme: theme, model: model, onChoose: context.choose,
                onManage: { context.manage(opensNewProfile: false, selection: selection, openSettings: openSettings) },
                onClose: { context.isOpen = false }
            )
        }
        .onChange(of: context.isOpen) { _, open in
            guard open else { return }
            Task { await context.refreshMachines() }
        }
        .background(WindowReporter { window in if let window { context.anchorWindow = window } })
        .onAppear { context.mount() }
        .onDisappear { context.unmount() }
        .accessibilityIdentifier("flock.rail.profilePicker")
    }

    /// The full name, which a narrow rail truncates, over what a click does.
    static func tooltip(name: String, isLocked: Bool) -> String {
        "\(name)\n" + (isLocked
            ? ProfilesSettingsSection.lockedNote
            : "Switch profile (\(ProfilePickerContext.shortcutLabel)), last profile (\(SwitcherTrigger.controlBacktick.label))")
    }
}

/// The closed picker: marker and dot for a machine, the name, and the
/// pop-up chevron, on a bordered control that washes on hover.
struct ProfilePickerLabel: View {
    let theme: Theme
    let title: String
    let isMachine: Bool
    let dot: ProfileConnectionDot?
    var showsChevron = true
    var interaction: ControlInteraction = .rest

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ChromeMetrics.WorkspaceRow.cornerRadius) }

    var body: some View {
        HStack(spacing: ChromeMetrics.ProfilePicker.spacing) {
            if isMachine {
                ProfileMachineMarker(theme: theme)
            }
            Text(title)
                .font(ChromeType.profilePickerName)
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .truncationMode(.tail)
            if let dot {
                ProfileDot(theme: theme, dot: dot)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(ChromeType.profilePickerChevron)
                    .foregroundStyle(theme.textLabel)
                    .frame(width: ChromeMetrics.ProfilePicker.chevron)
            }
        }
        .frame(height: ChromeMetrics.WorkspaceRow.contentHeight)
        .padding(.vertical, ChromeMetrics.ProfilePicker.verticalPadding)
        .padding(.horizontal, ChromeMetrics.ProfilePicker.horizontalPadding)
        .background {
            GridStateWash(theme: theme, shape: AnyShape(shape), interaction: interaction)
        }
        .overlay { shape.strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth) }
        .contentShape(shape)
    }
}

struct ProfileMachineMarker: View {
    let theme: Theme

    var body: some View {
        Image(systemName: "network")
            .font(ChromeType.profilePickerMarker)
            .foregroundStyle(theme.textLabel)
            .frame(width: ChromeMetrics.ProfilePicker.marker)
            .accessibilityLabel("herdr machine")
    }
}

struct ProfileDot: View {
    let theme: Theme
    let dot: ProfileConnectionDot

    var body: some View {
        Circle()
            .fill(dot.color(in: theme))
            .frame(width: ChromeMetrics.ProfilePicker.dot, height: ChromeMetrics.ProfilePicker.dot)
            .accessibilityLabel(dot == .live ? "connected" : "not connected")
    }
}

/// The open list: Default and the user's profiles, a rule, the machines, a
/// rule, then Manage Profiles. Opens on the current profile; up and down
/// move the pick, Return takes it, Esc closes.
struct ProfilePickerList: View {
    let theme: Theme
    let model: ProfilePickerModel
    let onChoose: (String) -> Void
    let onManage: () -> Void
    let onClose: () -> Void
    /// Per row, for renders; `rows.count` is Manage Profiles.
    var forced: [Int: ControlInteraction] = [:]

    /// By id, so a machine sync that reorders or drops rows while the list
    /// is open moves the pick with its row.
    @State private var pickedID: String?
    @State private var hovered: Int?
    @FocusState private var isFocused: Bool

    private var manageIndex: Int { model.rows.count }
    private var picked: Int { model.pickIndex(for: pickedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ProfilePicker.listRowSpacing) {
            ForEach(Array(model.local.enumerated()), id: \.element.id) { offset, row in
                rowButton(row, index: offset)
            }
            if !model.machines.isEmpty {
                rule
                ForEach(Array(model.machines.enumerated()), id: \.element.id) { offset, row in
                    rowButton(row, index: model.local.count + offset)
                }
            }
            rule
            Button(action: onManage) {
                Text("Manage Profiles\u{2026}")
                    .font(ChromeType.profilePickerRow)
                    .foregroundStyle(theme.textDim)
                    .padding(.leading, ChromeMetrics.ProfilePicker.listHorizontalPadding + ChromeMetrics.ProfilePicker.check
                        + ChromeMetrics.ProfilePicker.spacing)
                    .padding(.trailing, ChromeMetrics.ProfilePicker.listHorizontalPadding)
                    .padding(.vertical, ChromeMetrics.ProfilePicker.listRowVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PickedRowStyle(
                theme: theme, isPicked: picked == manageIndex, hovering: hovered == manageIndex, forced: forced[manageIndex]
            ))
            .modifier(ProfilePickerRowInset())
            .onHover { hover(manageIndex, $0) }
            .accessibilityIdentifier("flock.profilePicker.manage")
        }
        .padding(.vertical, ChromeMetrics.ProfilePicker.listVerticalPadding)
        .frame(width: ChromeMetrics.ProfilePicker.listWidth)
        // Opaque, as the pin folder question is: the popover's own material
        // lets the terminal under it show through the text.
        .background(RoundedRectangle(cornerRadius: ChromeRadius.container).fill(Color(theme.palette.panelBg)))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeRadius.container)
                .strokeBorder(Color(theme.palette.surface1), lineWidth: ChromeMetrics.ruleWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.container))
        .background(PopoverAppearancePin(isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow, phases: .down) { _ in
            pickedID = model.pickID(stepping: pickedID, by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            pickedID = model.pickID(stepping: pickedID, by: 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            take(picked)
            return .handled
        }
        .onKeyPress(.escape, phases: .down) { _ in
            onClose()
            return .handled
        }
        .onAppear { isFocused = true }
        .accessibilityIdentifier("flock.profilePicker.list")
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.rule)
            .frame(height: ChromeMetrics.ruleWidth)
            .padding(.vertical, ChromeMetrics.ProfilePicker.listSectionGap)
            .padding(.horizontal, ChromeMetrics.ProfilePicker.listRowInset)
    }

    private func rowButton(_ row: ProfilePickerRow, index: Int) -> some View {
        Button { onChoose(row.id) } label: {
            HStack(spacing: ChromeMetrics.ProfilePicker.spacing) {
                Image(systemName: "checkmark")
                    .font(ChromeType.profilePickerCheck)
                    .foregroundStyle(theme.accent)
                    .frame(width: ChromeMetrics.ProfilePicker.check)
                    .opacity(row.isCurrent ? 1 : 0)
                if row.isMachine {
                    ProfileMachineMarker(theme: theme)
                }
                Text(row.title)
                    .font(ChromeType.profilePickerRow)
                    .foregroundStyle(row.isCurrent ? theme.textStrong : theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let dot = row.dot {
                    ProfileDot(theme: theme, dot: dot)
                }
                Spacer(minLength: 0)
                if index == picked {
                    Text("\u{21A9}")
                        .font(ChromeType.profilePickerHint)
                        .foregroundStyle(theme.textLabel)
                }
            }
            .padding(.horizontal, ChromeMetrics.ProfilePicker.listHorizontalPadding)
            .padding(.vertical, ChromeMetrics.ProfilePicker.listRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickedRowStyle(theme: theme, isPicked: index == picked, hovering: hovered == index, forced: forced[index]))
        .modifier(ProfilePickerRowInset())
        .onHover { hover(index, $0) }
        .accessibilityIdentifier("flock.profilePicker.row.\(row.id)")
    }

    private func hover(_ index: Int, _ inside: Bool) {
        hovered = inside ? index : (hovered == index ? nil : hovered)
    }

    private func take(_ index: Int) {
        if index == manageIndex {
            onManage()
        } else if model.rows.indices.contains(index) {
            onChoose(model.rows[index].id)
        }
    }
}

/// Rows sit inside the panel's edge with rounded fills, as a menu's do.
private struct ProfilePickerRowInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.control))
            .padding(.horizontal, ChromeMetrics.ProfilePicker.listRowInset)
    }
}
