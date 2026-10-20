import FlockCore
import SwiftUI

/// Which herdr server the current profile talks to. New Server and Custom
/// Socket Path open their field inline under the row rather than a sheet.
struct ServerSettingsSection: View {
    let picker: ServerPicker

    private enum Field { case newServer, customPath }

    @State private var field: Field?
    @State private var name = ""
    @State private var path = ""

    var body: some View {
        Section {
            LabeledContent {
                Menu(picker.currentLabel) {
                    ForEach(picker.entries, id: \.socketPath) { entry in
                        Toggle(isOn: Binding(
                            get: { picker.isCurrent(entry) },
                            set: { _ in Task { await picker.choose(entry) } }
                        )) {
                            Text(entry.name)
                            Text(entry.isRunning ? "running" : "stopped")
                        }
                    }
                    Divider()
                        .onAppear { Task { await picker.refresh() } }
                    Button("New Server…") { field = .newServer }
                        .accessibilityIdentifier("flock.settings.server.new")
                    Button("Custom Socket Path…") { field = .customPath }
                        .accessibilityIdentifier("flock.settings.server.custom")
                }
                .fixedSize()
                .disabled(picker.isLocked)
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
            if let failure = picker.failure {
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
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { run(perform) }
            Button(action) { run(perform) }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
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
