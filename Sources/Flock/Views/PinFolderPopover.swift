import FlockCore
import SwiftUI

/// A new pin's question, anchored to its rail row: the folders worth
/// offering, the likeliest picked, and Finder only behind Other. Return
/// confirms the picked one; Esc keeps the first, which the pin already holds.
struct PinFolderPopover: View {
    let theme: Theme
    let name: String
    let ask: PinFolderAsk
    let onChoose: (String) -> Void
    let onOther: () -> Void

    @State private var picked = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.PinFolderPopover.rowSpacing) {
            HStack(spacing: ChromeMetrics.PinFolderPopover.titleSpacing) {
                Image(systemName: "pin.fill")
                    .font(ChromeType.pinFolderGlyph)
                    .foregroundStyle(theme.accent)
                Text("\(name) opens in")
                    .font(ChromeType.pinFolderTitle)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            .padding(.horizontal, ChromeMetrics.PinFolderPopover.horizontalPadding)
            .padding(.bottom, ChromeMetrics.PinFolderPopover.titleBottomPadding)
            ForEach(Array(ask.choices.enumerated()), id: \.offset) { index, choice in
                row(choice, isPicked: index == picked)
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(choice.folder) }
                    .onHover { if $0 { picked = index } }
            }
            Rectangle()
                .fill(theme.rule)
                .frame(height: ChromeMetrics.ruleWidth)
            Text("Other\u{2026}")
                .font(ChromeType.pinFolderOther)
                .foregroundStyle(theme.textDim)
                .padding(.leading, ChromeMetrics.PinFolderPopover.otherLeading)
                .padding(.vertical, ChromeMetrics.PinFolderPopover.otherVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOther)
                .accessibilityAddTraits(.isButton)
        }
        .padding(.vertical, ChromeMetrics.PinFolderPopover.verticalPadding)
        .frame(width: ChromeMetrics.PinFolderPopover.width)
        // Opaque, as the symbol picker is: the popover's own material lets
        // the terminal under it show through the text.
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
            picked = max(picked - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            picked = min(picked + 1, ask.choices.count - 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            onChoose(ask.choices[picked].folder)
            return .handled
        }
        .onAppear { isFocused = true }
        .accessibilityIdentifier("flock.pin.folderAsk")
    }

    private func row(_ choice: PinFolderAsk.Choice, isPicked: Bool) -> some View {
        HStack(spacing: ChromeMetrics.PinFolderPopover.titleSpacing) {
            Circle()
                .strokeBorder(
                    isPicked ? theme.accent : theme.textLabel,
                    lineWidth: isPicked ? ChromeMetrics.PinFolderPopover.pickedRing : ChromeMetrics.PinFolderPopover.ring
                )
                .frame(width: ChromeMetrics.PinFolderPopover.radio, height: ChromeMetrics.PinFolderPopover.radio)
            VStack(alignment: .leading, spacing: 1) {
                Text((choice.folder as NSString).abbreviatingWithTildeInPath)
                    .font(ChromeType.pinFolderPath)
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(Self.reason(choice.reason))
                    .font(ChromeType.pinFolderReason)
                    .foregroundStyle(theme.textLabel)
            }
            Spacer(minLength: 0)
            if isPicked {
                Text("\u{21A9}")
                    .font(ChromeType.pinFolderReason)
                    .foregroundStyle(theme.textLabel)
            }
        }
        .padding(.horizontal, ChromeMetrics.PinFolderPopover.horizontalPadding)
        .padding(.vertical, ChromeMetrics.PinFolderPopover.rowVerticalPadding)
        .background(isPicked ? theme.selection : .clear)
    }

    static func reason(_ reason: PinFolderAsk.Choice.Reason) -> String {
        switch reason {
        case .shellNow: "where the shell is now"
        case .shellLastSeen: "where the shell was last seen"
        case .shellStarted: "where it started"
        }
    }
}
