import Foundation

/// A `[[keys.command]]` entry: a key bound to something herdr runs itself.
public struct HerdrCommandBinding: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case shell
        case pane
        case popup
        case pluginAction = "plugin_action"
    }

    public var command: String
    public var kind: Kind
    public var summary: String?

    public init(command: String, kind: Kind, summary: String? = nil) {
        self.command = command
        self.kind = kind
        self.summary = summary
    }
}

/// What a bound key does, named after the `[keys]` field it comes from.
public enum HerdrAction: Equatable, Sendable {
    case help
    case settings
    case newWorkspace
    case newWorktree
    case openWorktree
    case removeWorktree
    case renameWorkspace
    case closeWorkspace
    case workspacePicker
    case openNavigator
    case detach
    case reloadConfig
    case openNotificationTarget
    case previousWorkspace
    case nextWorkspace
    case previousAgent
    case nextAgent
    case focusAgent(Int)
    case newTab
    case renameTab
    case previousTab
    case nextTab
    case moveTabPrevious
    case moveTabNext
    case switchTab(Int)
    case switchWorkspace(Int)
    case closeTab
    case renamePane
    case editScrollback
    case copyMode
    case focusPane(PaneDirection)
    case swapPane(PaneDirection)
    case lastPane
    case cyclePaneNext
    case cyclePanePrevious
    case splitVertical
    case splitHorizontal
    case closePane
    case zoom
    case resizeMode
    case resizePane(PaneDirection)
    case toggleSidebar
    case command(HerdrCommandBinding)
}

public enum HerdrBindingTrigger: Equatable, Sendable {
    /// A key that acts on its own, with no prefix ahead of it.
    case direct(HerdrKeyCombo)
    case prefixed(HerdrKeyCombo)
}

public struct HerdrBinding: Equatable, Sendable {
    public var trigger: HerdrBindingTrigger
    /// The binding as the config spells it, for anything that has to name the
    /// key back to the user.
    public var label: String
    public var action: HerdrAction
}

/// Every key herdr's config binds, read the way herdr reads it: user values
/// claim their keys first, then herdr's own defaults fill in whatever is left
/// unclaimed.
public struct HerdrKeybindings: Equatable, Sendable {
    public var prefix: HerdrKeyCombo
    public var bindings: [HerdrBinding]

    public static let defaults = HerdrKeybindings.read(configText: "")

    public static func read(configText: String) -> HerdrKeybindings {
        HerdrKeybindingsBuilder(section: HerdrConfigToml.keysSection(in: configText)).build()
    }

    public func direct(matching press: HerdrKeyPress) -> HerdrBinding? {
        bindings.first { binding in
            guard case .direct(let combo) = binding.trigger else { return false }
            return combo.matches(press)
        }
    }

    /// The prefix-mode binding `press` runs, retrying against the character
    /// the key generated when the key itself matched nothing: that is what
    /// resolves a binding on a glyph the layout only produces with modifiers.
    public func prefixed(matching press: HerdrKeyPress) -> HerdrBinding? {
        if let binding = prefixedByCombo(press) { return binding }
        guard let text = press.generatedText, text.count == 1, let character = text.first,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return prefixedByCombo(HerdrKeyPress(code: .character(character)))
    }

    private func prefixedByCombo(_ press: HerdrKeyPress) -> HerdrBinding? {
        bindings.first { binding in
            guard case .prefixed(let combo) = binding.trigger else { return false }
            return combo.matches(press)
        }
    }
}

/// herdr's `validated_keybinds`, which is a two-pass build rather than a
/// merge: the fields the user wrote claim their keys first, then herdr's
/// defaults fill in every field the user left alone, skipping any whose key
/// a user binding already took.
private struct HerdrKeybindingsBuilder {
    let section: HerdrKeysSection

    private struct Field: Sendable {
        let name: String
        let fallbackName: String?
        let defaultBinding: String
        let action: @Sendable (Int) -> HerdrAction
        let isIndexed: Bool

        init(
            _ name: String, _ defaultBinding: String, _ action: HerdrAction, alias fallbackName: String? = nil
        ) {
            self.name = name
            self.fallbackName = fallbackName
            self.defaultBinding = defaultBinding
            self.action = { _ in action }
            self.isIndexed = false
        }

        init(indexed name: String, _ defaultBinding: String, _ action: @escaping @Sendable (Int) -> HerdrAction) {
            self.name = name
            self.fallbackName = nil
            self.defaultBinding = defaultBinding
            self.action = action
            self.isIndexed = true
        }
    }

    /// The order herdr applies its fields in, which is what decides which of
    /// two bindings on one key is the one that survives.
    private static let fields: [Field] = [
        Field("help", "prefix+?", .help),
        Field("settings", "prefix+s", .settings),
        Field("new_workspace", "prefix+shift+n", .newWorkspace),
        Field("new_worktree", "prefix+shift+g", .newWorktree),
        Field("open_worktree", "", .openWorktree),
        Field("remove_worktree", "", .removeWorktree),
        Field("rename_workspace", "prefix+shift+w", .renameWorkspace),
        Field("close_workspace", "prefix+shift+d", .closeWorkspace),
        Field("workspace_picker", "prefix+w", .workspacePicker),
        Field("goto", "prefix+g", .openNavigator),
        Field("detach", "prefix+q", .detach),
        Field("reload_config", "prefix+shift+r", .reloadConfig),
        Field("open_notification_target", "prefix+o", .openNotificationTarget),
        Field("previous_workspace", "", .previousWorkspace),
        Field("next_workspace", "", .nextWorkspace),
        Field("previous_agent", "", .previousAgent),
        Field("next_agent", "", .nextAgent),
        Field(indexed: "focus_agent", "") { .focusAgent($0) },
        Field("new_tab", "prefix+c", .newTab),
        Field("rename_tab", "prefix+shift+t", .renameTab),
        Field("previous_tab", "prefix+p", .previousTab),
        Field("next_tab", "prefix+n", .nextTab),
        Field("move_tab_previous", "", .moveTabPrevious),
        Field("move_tab_next", "", .moveTabNext),
        Field(indexed: "switch_tab", "prefix+1..9") { .switchTab($0) },
        Field(indexed: "switch_workspace", "") { .switchWorkspace($0) },
        Field("close_tab", "prefix+shift+x", .closeTab),
        Field("rename_pane", "prefix+shift+p", .renamePane),
        Field("edit_scrollback", "prefix+e", .editScrollback),
        Field("copy_mode", "prefix+[", .copyMode),
        Field("focus_pane_left", "prefix+h", .focusPane(.left)),
        Field("focus_pane_down", "prefix+j", .focusPane(.down)),
        Field("focus_pane_up", "prefix+k", .focusPane(.up)),
        Field("focus_pane_right", "prefix+l", .focusPane(.right)),
        Field("swap_pane_left", "prefix+shift+h", .swapPane(.left)),
        Field("swap_pane_down", "prefix+shift+j", .swapPane(.down)),
        Field("swap_pane_up", "prefix+shift+k", .swapPane(.up)),
        Field("swap_pane_right", "prefix+shift+l", .swapPane(.right)),
        Field("last_pane", "", .lastPane),
        Field("cycle_pane_next", "prefix+tab", .cyclePaneNext),
        Field("cycle_pane_previous", "prefix+shift+tab", .cyclePanePrevious),
        Field("split_vertical", "prefix+v", .splitVertical),
        Field("split_horizontal", "prefix+minus", .splitHorizontal),
        Field("close_pane", "prefix+x", .closePane),
        Field("zoom", "prefix+z", .zoom, alias: "fullscreen"),
        Field("resize_mode", "prefix+r", .resizeMode),
        Field("resize_pane_left", "", .resizePane(.left)),
        Field("resize_pane_down", "", .resizePane(.down)),
        Field("resize_pane_up", "", .resizePane(.up)),
        Field("resize_pane_right", "", .resizePane(.right)),
        Field("toggle_sidebar", "prefix+b", .toggleSidebar),
    ]

    private var prefix: HerdrKeyCombo {
        section.values["prefix"]?.first.flatMap(HerdrKeyCombo.parse) ?? HerdrKeyCombo(.character("b"), .control)
    }

    func build() -> HerdrKeybindings {
        let prefix = self.prefix
        var claimedDirect: Set<HerdrKeyCombo> = [prefix]
        var claimedPrefixed: Set<HerdrKeyCombo> = []
        var bindings: [HerdrBinding] = []

        for pass in [true, false] {
            for field in Self.fields {
                let written = userSpellings(field)
                guard (written != nil) == pass else { continue }
                let spellings = written ?? (field.defaultBinding.isEmpty ? [] : [field.defaultBinding])
                for spelling in spellings {
                    bindings.append(
                        contentsOf: accept(
                            spelling, field: field, prefix: prefix,
                            direct: &claimedDirect, prefixed: &claimedPrefixed
                        )
                    )
                }
            }
            guard pass else { continue }
            for table in section.commands {
                guard let command = command(from: table) else { continue }
                for spelling in table["key"] ?? [] {
                    bindings.append(
                        contentsOf: accept(
                            spelling, action: { _ in .command(command) }, isIndexed: false, prefix: prefix,
                            direct: &claimedDirect, prefixed: &claimedPrefixed
                        )
                    )
                }
            }
        }
        return HerdrKeybindings(prefix: prefix, bindings: bindings)
    }

    /// What the user wrote for `field`, blanks dropped, or `nil` when they
    /// wrote nothing at all and herdr's own default is what applies.
    private func userSpellings(_ field: Field) -> [String]? {
        guard let written = section.values[field.name] ?? field.fallbackName.flatMap({ section.values[$0] })
        else { return nil }
        return written.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func command(from table: [String: [String]]) -> HerdrCommandBinding? {
        guard let command = table["command"]?.first, !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return HerdrCommandBinding(
            command: command,
            kind: table["type"]?.first.flatMap(HerdrCommandBinding.Kind.init(rawValue:)) ?? .shell,
            summary: table["description"]?.first
        )
    }

    private func accept(
        _ spelling: String, field: Field, prefix: HerdrKeyCombo,
        direct: inout Set<HerdrKeyCombo>, prefixed: inout Set<HerdrKeyCombo>
    ) -> [HerdrBinding] {
        accept(
            spelling, action: field.action, isIndexed: field.isIndexed, prefix: prefix,
            direct: &direct, prefixed: &prefixed
        )
    }

    private func accept(
        _ spelling: String, action: (Int) -> HerdrAction, isIndexed: Bool, prefix: HerdrKeyCombo,
        direct: inout Set<HerdrKeyCombo>, prefixed: inout Set<HerdrKeyCombo>
    ) -> [HerdrBinding] {
        let trimmed = spelling.trimmingCharacters(in: .whitespaces)
        let isPrefixed = trimmed.hasPrefix("prefix+")
        let body = isPrefixed ? String(trimmed.dropFirst("prefix+".count)) : trimmed

        let combos: [(HerdrKeyCombo, Int)]
        if let rangeModifiers = Self.rangeModifiers(of: body) {
            // A range is only ever an indexed action's; herdr disables one
            // written anywhere else rather than binding nine keys to it.
            guard isIndexed else { return [] }
            combos = (1...9).map { (HerdrKeyCombo(.character(Character("\($0)")), rangeModifiers), $0 - 1) }
        } else if let combo = HerdrKeyCombo.parse(body) {
            combos = [(combo, 0)]
        } else {
            return []
        }

        var accepted: [HerdrBinding] = []
        for (combo, index) in combos {
            if isPrefixed {
                guard combo != prefix, prefixed.insert(combo).inserted else { continue }
            } else {
                guard !Self.isUnmodifiedPrintable(combo), direct.insert(combo).inserted else { continue }
            }
            let label = isPrefixed ? "prefix+\(Self.spell(combo))" : Self.spell(combo)
            accepted.append(
                HerdrBinding(
                    trigger: isPrefixed ? .prefixed(combo) : .direct(combo),
                    label: label,
                    action: action(index)
                )
            )
        }
        return accepted
    }

    /// The modifiers of a `1..9` range spelling, or `nil` when the body is an
    /// ordinary key.
    private static func rangeModifiers(of body: String) -> HerdrKeyModifiers? {
        var modifiers = HerdrKeyModifiers()
        var sawRange = false
        for part in body.split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token == "1..9" {
                if sawRange { return nil }
                sawRange = true
            } else if let combo = HerdrKeyCombo.parse("\(token)+x"), combo.code == .character("x") {
                modifiers.formUnion(combo.modifiers)
            } else {
                return nil
            }
        }
        return sawRange ? modifiers : nil
    }

    /// A key that types a character on its own. herdr refuses to bind one
    /// directly, because doing so would take it away from the program.
    private static func isUnmodifiedPrintable(_ combo: HerdrKeyCombo) -> Bool {
        guard case .character = combo.code else { return false }
        return combo.modifiers.subtracting(.shift).isEmpty
    }

    private static func spell(_ combo: HerdrKeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.control) { parts.append("ctrl") }
        if combo.modifiers.contains(.option) { parts.append("alt") }
        if combo.modifiers.contains(.shift), combo.code != .backTab { parts.append("shift") }
        if combo.modifiers.contains(.command) { parts.append("cmd") }
        if combo.modifiers.contains(.hyper) { parts.append("hyper") }
        switch combo.code {
        case .character(" "): parts.append("space")
        case .character(let character): parts.append(String(character))
        case .enter: parts.append("enter")
        case .escape: parts.append("esc")
        case .tab: parts.append("tab")
        case .backTab: return (parts + ["shift", "tab"]).joined(separator: "+")
        case .backspace: parts.append("backspace")
        case .left: parts.append("left")
        case .right: parts.append("right")
        case .up: parts.append("up")
        case .down: parts.append("down")
        case .function(let number): parts.append("f\(number)")
        }
        return parts.joined(separator: "+")
    }
}
