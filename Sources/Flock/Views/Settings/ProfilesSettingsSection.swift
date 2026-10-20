import FlockCore
import SwiftUI

/// Settings > Profiles. The current profile switches only through
/// `switchProfile` and its server changes only through `changeServer`; any
/// other profile's server is written to the store directly, since nothing is
/// attached to it.
struct ProfilesSettingsSection: View {
    static let lockedNote = "Profiles are off while HERDR_SOCKET_PATH is set."

    let profiles: ProfileStore
    let picker: ServerPicker?
    let isLocked: Bool
    let switchProfile: (String) async -> Bool
    let changeServer: (String?) async -> Bool
    let selection: SettingsTabSelection
    let home: String

    struct Draft {
        var customServer = false
        var customPathProfile: String?
    }

    private enum InlineField: Equatable {
        case rename(String)
        case customPath(String)
    }

    private enum NewServer: Hashable {
        case start
        case existing(String?)
        case custom
    }

    @State private var field: InlineField?
    @State private var fieldText = ""
    @State private var pendingDelete: FlockProfile?
    @State private var newName: String
    @State private var newServer: NewServer = .start
    /// nil while the server name still follows the profile name.
    @State private var editedServerName: String?
    @State private var newPath = ""
    @State private var isCreating = false

    init(
        profiles: ProfileStore, picker: ServerPicker?, isLocked: Bool,
        switchProfile: @escaping (String) async -> Bool, changeServer: @escaping (String?) async -> Bool,
        selection: SettingsTabSelection, home: String = NSHomeDirectory(), draftName: String = "", draft: Draft? = nil
    ) {
        self.profiles = profiles
        self.picker = picker
        self.isLocked = isLocked
        self.switchProfile = switchProfile
        self.changeServer = changeServer
        self.selection = selection
        self.home = home
        _newName = State(initialValue: draftName)
        if draft?.customServer == true { _newServer = State(initialValue: .custom) }
        if let id = draft?.customPathProfile { _field = State(initialValue: .customPath(id)) }
    }

    /// herdr's session-name alphabet, from a profile name.
    static func serverName(for profileName: String) -> String {
        let mapped = profileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().map { character -> Character in
            let allowed = (character.isASCII && (character.isLetter || character.isNumber)) || "._-".contains(character)
            return allowed ? character : "-"
        }
        return String(String(mapped).drop { $0 == "." || $0 == "-" })
    }

    var body: some View {
        if isLocked {
            Section {
                Text(Self.lockedNote)
                    .accessibilityIdentifier("flock.settings.profiles.locked")
            }
        } else {
            Section {
                ForEach(profiles.profiles) { profile in
                    row(profile)
                    inlineField(for: profile)
                }
            }
            .alert(
                pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { profile in
                Button("Delete", role: .destructive) { _ = profiles.delete(profile.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its settings and pins are removed. Its herdr server keeps running.")
            }
            .task { await picker?.refresh() }
            .onDisappear { closeForm() }
            newProfileSection
        }
    }

    private var entries: [HerdrSessionEntry] { picker?.entries ?? [] }

    private func row(_ profile: FlockProfile) -> some View {
        let isCurrent = profile.id == profiles.currentID
        return HStack(spacing: 8) {
            Text(profile.name)
                .lineLimit(1)
            if isCurrent {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityIdentifier("flock.settings.profiles.current")
            }
            Spacer(minLength: 8)
            serverMenu(for: profile)
            Button("Switch") { Task { _ = await switchProfile(profile.id) } }
                .hiddenKeepingSpace(isCurrent)
                .accessibilityIdentifier("flock.settings.profiles.switch")
            Button("Rename") {
                fieldText = profile.name
                field = .rename(profile.id)
            }
            .accessibilityIdentifier("flock.settings.profiles.rename")
            Button {
                pendingDelete = profile
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
            .disabled(profile.id == FlockProfile.defaultID || isCurrent)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("flock.settings.profiles.delete")
        }
        .accessibilityIdentifier("flock.settings.profiles.row")
    }

    private func serverMenu(for profile: FlockProfile) -> some View {
        let socket = HerdrServerAddress.normalize(profiles.socketPath(of: profile), home: home)
        return Menu(HerdrServerAddress(socketPath: socket, home: home).label) {
            ForEach(entries, id: \.socketPath) { entry in
                Toggle(isOn: Binding(
                    get: { HerdrServerAddress.normalize(entry.socketPath, home: home) == socket },
                    set: { _ in setServer(entry.isDefault ? nil : entry.socketPath, for: profile.id) }
                )) {
                    entry.menuTitle
                }
            }
            Divider()
            Button("Custom Socket Path…") {
                fieldText = ""
                field = .customPath(profile.id)
            }
        }
        .fixedSize()
        .disabled(picker?.isBusy ?? false)
        .onHover { inside in
            if inside { Task { await picker?.refresh() } }
        }
        .accessibilityIdentifier("flock.settings.profiles.server")
    }

    @ViewBuilder
    private func inlineField(for profile: FlockProfile) -> some View {
        switch field {
        case .rename(profile.id):
            fieldRow(placeholder: "Profile name", action: "Rename") {
                profiles.rename(profile.id, to: fieldText)
            }
            .accessibilityIdentifier("flock.settings.profiles.renameField")
        case .customPath(profile.id):
            fieldRow(placeholder: "Socket path", action: "Use") {
                guard let socket = customSocket(fieldText) else { return }
                setServer(socket, for: profile.id)
            }
            .accessibilityIdentifier("flock.settings.profiles.customField")
        default:
            EmptyView()
        }
    }

    private func fieldRow(placeholder: String, action: String, perform: @escaping () -> Void) -> some View {
        let isEmpty = fieldText.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack {
            TextField(placeholder, text: $fieldText, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit {
                    guard !isEmpty else { return }
                    perform()
                    field = nil
                }
            Button(action) {
                perform()
                field = nil
            }
            .disabled(isEmpty)
            Button("Cancel") { field = nil }
        }
    }

    private var newProfileSection: some View {
        Section {
            if selection.opensNewProfile {
                TextField("Name", text: $newName)
                    .accessibilityIdentifier("flock.settings.profiles.newName")
                Picker("Server", selection: $newServer) {
                    Text("New server").tag(NewServer.start)
                    ForEach(entries, id: \.socketPath) { entry in
                        entry.menuTitle.tag(NewServer.existing(entry.isDefault ? nil : entry.socketPath))
                    }
                    Text("Custom Socket Path…").tag(NewServer.custom)
                }
                .accessibilityIdentifier("flock.settings.profiles.newServer")
                switch newServer {
                case .start:
                    TextField("Server name", text: serverName)
                        .accessibilityIdentifier("flock.settings.profiles.newServerName")
                case .custom:
                    TextField("Socket path", text: $newPath)
                        .accessibilityIdentifier("flock.settings.profiles.newPath")
                case .existing:
                    EmptyView()
                }
                if let failure = picker?.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("flock.settings.profiles.error")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { closeForm() }
                    Button("Create and Switch") { Task { await create() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                        .accessibilityIdentifier("flock.settings.profiles.create")
                }
            } else {
                HStack {
                    Spacer()
                    Button("New Profile…") { selection.opensNewProfile = true }
                        .accessibilityIdentifier("flock.settings.profiles.new")
                }
            }
        } header: {
            if selection.opensNewProfile { Text("New Profile") }
        }
    }

    private var serverName: Binding<String> {
        Binding(
            get: { editedServerName ?? Self.serverName(for: newName) },
            set: { editedServerName = $0 }
        )
    }

    private var canCreate: Bool {
        guard !isCreating, !(picker?.isBusy ?? false),
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch newServer {
        case .start: return picker != nil && !serverName.wrappedValue.isEmpty
        case .existing: return true
        case .custom: return customSocket(newPath) != nil
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        let socket: String?
        switch newServer {
        case .start:
            guard let picker, let started = await picker.startServer(name: serverName.wrappedValue) else { return }
            socket = started
        case .existing(let path):
            socket = path
        case .custom:
            guard let path = customSocket(newPath) else { return }
            socket = path
        }
        guard let profile = profiles.create(name: newName, socketPath: socket) else { return }
        closeForm()
        _ = await switchProfile(profile.id)
    }

    private func closeForm() {
        selection.opensNewProfile = false
        newName = ""
        newServer = .start
        editedServerName = nil
        newPath = ""
    }

    /// nil for an empty path; the default server's socket comes back as
    /// `.some(nil)` so the profile follows herdr's default.
    private func customSocket(_ path: String) -> String?? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let address = HerdrServerAddress(socketPath: trimmed, home: home)
        return .some(address == .defaultServer ? nil : address.socketPath(home: home))
    }

    enum ServerRoute: Equatable {
        case changeServer
        case setSocket
    }

    static func serverRoute(for id: String, currentID: String) -> ServerRoute {
        id == currentID ? .changeServer : .setSocket
    }

    /// Reads the current profile when it acts, not when the menu was drawn:
    /// a switch can land while a row's menu is open.
    private func setServer(_ socket: String?, for id: String) {
        switch Self.serverRoute(for: id, currentID: profiles.currentID) {
        case .changeServer: Task { _ = await changeServer(socket) }
        case .setSocket: profiles.setSocket(socket, for: id)
        }
    }
}

private extension View {
    /// Keeps the view's space so the controls after it stay in their columns.
    func hiddenKeepingSpace(_ isHidden: Bool) -> some View {
        opacity(isHidden ? 0 : 1)
            .disabled(isHidden)
            .accessibilityHidden(isHidden)
    }
}
