import FlockCore
import SwiftUI

/// What a pane offers for the link the pointer rested on: open it, and
/// reveal a file or copy an address.
struct LinkChipView: View {
    let theme: Theme
    let link: PaneLink
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            LinkChipButton(theme: theme, title: "Open", symbol: "arrow.up.right", id: "open", action: onOpen)
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth, height: ChromeMetrics.LinkChip.dividerHeight)
            switch link {
            case .file:
                LinkChipButton(theme: theme, title: "Reveal", symbol: "folder", id: "reveal", action: onReveal)
            case .web:
                LinkChipButton(theme: theme, title: "Copy", symbol: "doc.on.doc", id: "copy", action: onCopy)
            }
        }
        .frame(height: ChromeMetrics.LinkChip.height)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.LinkChip.cornerRadius)
                .fill(theme.chrome)
                .overlay(
                    RoundedRectangle(cornerRadius: ChromeMetrics.LinkChip.cornerRadius)
                        .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
                )
                .shadow(color: .black.opacity(0.25), radius: ChromeMetrics.LinkChip.shadowRadius, y: 2)
        )
        .fixedSize()
    }
}

private struct LinkChipButton: View {
    let theme: Theme
    let title: String
    let symbol: String
    let id: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChromeMetrics.LinkChip.symbolGap) {
                Image(systemName: symbol)
                    .font(ChromeType.linkChipSymbol)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(ChromeType.linkChip)
                    .foregroundStyle(theme.textStrong)
            }
            .padding(.horizontal, ChromeMetrics.LinkChip.horizontalPadding)
            .frame(maxHeight: .infinity)
            .background { if isHovering { HoverWashFill(theme: theme, cornerRadius: ChromeMetrics.LinkChip.cornerRadius) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("flock.pane.link.\(id)")
    }
}
