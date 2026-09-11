import PaddockCore
import SwiftUI

/// The 42px tab strip: pill tabs for the selected workspace plus the
/// "protocol NN" readout. Read-only mirror + selection/jump only; stays
/// untested until the e2e suite per the task brief.
struct TabStrip: View {
    let theme: Theme
    let tabs: [TabRecord]
    let selectedTabID: TabID?
    let protocolVersion: Int
    let onSelect: (TabID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs, id: \.tabID) { tab in
                TabPill(theme: theme, tab: tab, isSelected: tab.tabID == selectedTabID)
                    .accessibilityIdentifier("paddock.strip.tab.\(tab.tabID.rawValue)")
                    .onTapGesture { onSelect(tab.tabID) }
            }
            Spacer(minLength: 0)
            Text("protocol \(protocolVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.overlay0)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.tabStripBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

private struct TabPill: View {
    let theme: Theme
    let tab: TabRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(tab.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.text : theme.subtext0)
            Text("\(tab.paneCount)")
                .font(.system(size: 10))
                .foregroundStyle(theme.overlay0)
            StatusDot(status: tab.agentStatus, theme: theme, size: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            // One neutral surface step above the strip (reusing paneHeaderBg,
            // itself one step above windowBg), not a raw hued surface field.
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.paneHeaderBg : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? theme.separator : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
