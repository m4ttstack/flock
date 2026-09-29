import FlockCore
import SwiftUI

struct CommandLineToolSection: View {
    let store: CommandLineToolStore

    var body: some View {
        Section(CommandLineTool.heading) {
            LabeledContent {
                if let title = CommandLineTool.actionTitle(for: store.state) {
                    Button(title) { store.performAction() }
                        .accessibilityIdentifier("flock.settings.commandLineTool.action")
                }
            } label: {
                Text(CommandLineTool.rowTitle)
                Text(CommandLineTool.body(for: store.state, name: store.name, linkPath: store.linkPath))
            }
            if let message = store.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
