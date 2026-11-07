import FlockCore
import SwiftUI

/// How panes sit on the canvas and how the focused one stands out.
struct PanesSettingsSection: View {
    let store: PaneAppearanceStore

    var body: some View {
        Section("Panes") {
            Picker(selection: Binding(get: { store.layout }, set: { store.select($0) })) {
                ForEach(PaneLayoutStyle.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Pane layout")
                Text("Boxes on the canvas, or panes filling it with a thin line between.")
            }
            .accessibilityIdentifier("flock.settings.paneLayout")
            Picker(selection: Binding(get: { store.focusStyle }, set: { store.select($0) })) {
                ForEach(PaneFocusStyle.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Pane focus")
                Text("How the pane with the keyboard stands out from the rest.")
            }
            .accessibilityIdentifier("flock.settings.paneFocus")
            LabeledContent {
                Slider(
                    value: Binding(get: { store.dimness }, set: { store.setDimness($0) }),
                    in: PaneAppearanceStore.dimnessRange
                )
                .frame(maxWidth: 200)
            } label: {
                Text("Dimness")
                Text("How far panes without focus recede, under Dim others and Drain colour.")
            }
            .disabled(store.focusStyle != .dimOthers && store.focusStyle != .drainColour)
            .accessibilityIdentifier("flock.settings.paneDimness")
            LabeledContent {
                Slider(
                    value: Binding(get: { store.desaturation }, set: { store.setDesaturation($0) }),
                    in: PaneAppearanceStore.desaturationRange
                )
                .frame(maxWidth: 200)
            } label: {
                Text("Desaturation")
                Text("How much colour panes without focus lose, under Drain colour.")
            }
            .disabled(store.focusStyle != .drainColour)
            .accessibilityIdentifier("flock.settings.paneDesaturation")
            Picker(selection: Binding(get: { store.statusLine }, set: { store.select($0) })) {
                ForEach(PaneStatusLineStyle.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Status line")
                Text("A line under each pane's header while its agent works. Blocked always breathes red.")
            }
            .accessibilityIdentifier("flock.settings.paneStatusLine")
        }
    }
}
