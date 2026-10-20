import FlockCore
import SwiftUI

/// Which herdr server the current profile talks to. New Server and Custom
/// Socket Path open their field inline under the row.
struct ServerSettingsSection: View {
    let picker: ServerPicker

    enum Field { case newServer, customPath }

    /// A field already open, with its text, as the section first draws.
    struct Draft {
        let field: Field
        let text: String
    }

    @State private var field: Field?
    @State private var name: String
    @State private var path: String

    init(picker: ServerPicker, draft: Draft? = nil) {
        self.picker = picker
        _field = State(initialValue: draft?.field)
        _name = State(initialValue: draft?.field == .newServer ? draft?.text ?? "" : "")
        _path = State(initialValue: draft?.field == .customPath ? draft?.text ?? "" : "")
    }

    var body: some View {
        Section {
            LabeledContent {
                Menu(picker.currentLabel) {
                    ForEach(picker.entries, id: \.socketPath) { entry in
                        Toggle(isOn: Binding(
                            get: { picker.isCurrent(entry) },
                            set: { _ in Task { await picker.choose(entry) } }
                        )) {
                            entry.menuTitle
                        }
                    }
                    Divider()
                    Button("New Server…") { field = .newServer }
                        .accessibilityIdentifier("flock.settings.server.new")
                    Button("Custom Socket Path…") { field = .customPath }
                        .accessibilityIdentifier("flock.settings.server.custom")
                }
                .fixedSize()
                .disabled(picker.isLocked || picker.isBusy)
                .onHover { inside in
                    if inside { Task { await picker.refresh() } }
                }
                .accessibilityIdentifier("flock.settings.server.menu")
            } label: {
                Text("Server")
                if let note = picker.lockedNote {
                    Text(note)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("flock.settings.server.locked")
                }
            }
            switch field {
            case .newServer:
                fieldRow(placeholder: "Server name", text: $name, action: "Start") {
                    await picker.startNew(name: name)
                }
                .accessibilityIdentifier("flock.settings.server.newField")
            case .customPath:
                fieldRow(placeholder: "Socket path", text: $path, action: "Use") {
                    await picker.chooseCustom(path: path)
                }
                .accessibilityIdentifier("flock.settings.server.customField")
            case nil:
                EmptyView()
            }
            if let failure = picker.failure, !picker.failureIsFromServerList {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("flock.settings.server.error")
            }
        }
        .task { await picker.refresh() }
    }

    private func fieldRow(
        placeholder: String, text: Binding<String>, action: String, perform: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack {
            TextField(placeholder, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { if !picker.isBusy { run(perform) } }
            Button(action) { run(perform) }
                .disabled(picker.isBusy || text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { close() }
        }
    }

    private func run(_ perform: @escaping @MainActor () async -> Void) {
        Task {
            await perform()
            if picker.failure == nil { close() }
        }
    }

    private func close() {
        field = nil
        name = ""
        path = ""
    }
}
