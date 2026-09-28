import FlockCore
import SwiftUI

/// Each rt command's modal keeps its own terminal text size; Cmd-plus and
/// Cmd-minus step the one on screen, and this sets any of them at rest.
struct RtModalTextSizeSection: View {
    let store: RtModalTextSizeStore

    var body: some View {
        Section("rt Modal Text Size") {
            ForEach(RtKind.allCases, id: \.self) { kind in
                Picker("rt \(kind.rawValue)", selection: Binding(get: { store.size(for: kind) }, set: { store.select($0, for: kind) })) {
                    ForEach(TerminalTextSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .accessibilityIdentifier("flock.settings.rtModalTextSize.\(kind.rawValue)")
            }
        }
    }
}
