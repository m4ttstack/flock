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
                .foregroundStyle(isSelected ? theme.chromeTextStrong : theme.chromeTextDim)
            StatusDot(status: tab.agentStatus, theme: theme, size: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            // The selected pill's own surface role -- see `Theme`'s doc on
            // `tabPillSelectedBg`/`tabPillSelectedBorder` for why these are
            // distinct roles from `separator` rather than a reuse of it.
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.tabPillSelectedBg : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? theme.tabPillSelectedBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
