import FlockCore
import SwiftUI

/// What a pane offers for the link the pointer rested on: open it, and
/// reveal a file or copy an address.
struct LinkChipView: View {
    let theme: Theme
    let link: PaneLink
    var flash: LinkChip.Action?
    /// A pasted image, shown above the buttons.
    var preview: NSImage?
    var previewLimit = CGSize.zero
    var onPreview: () -> Void = {}
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let preview {
                let size = Self.fit(preview.size, in: previewLimit)
                Image(nsImage: preview)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.tiny))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPreview)
                    .pointerStyle(.link)
                    .padding(ChromeMetrics.LinkChip.inset)
            }
            buttons
        }
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

    private static func fit(_ image: CGSize, in limit: CGSize) -> CGSize {
        let width = max(40, limit.width), height = max(40, limit.height)
        let scale = min(1, width / max(1, image.width), height / max(1, image.height))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            LinkChipButton(theme: theme, title: "Open", symbol: "arrow.up.right", id: "open", lit: flash == .open, action: onOpen)
            Rectangle()
                .fill(theme.rule)
                .frame(width: ChromeMetrics.ruleWidth, height: ChromeMetrics.LinkChip.dividerHeight)
            switch link {
            case .file:
                LinkChipButton(theme: theme, title: "Reveal", symbol: "folder", id: "reveal", lit: flash == .second, action: onReveal)
            case .web:
                LinkChipButton(theme: theme, title: "Copy", symbol: "doc.on.doc", id: "copy", lit: flash == .second, action: onCopy)
            }
        }
        .frame(height: ChromeMetrics.LinkChip.height)
    }
}

private struct LinkChipButton: View {
    let theme: Theme
    let title: String
    let symbol: String
    let id: String
    let lit: Bool
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
            .background {
                if lit {
                    RoundedRectangle(cornerRadius: ChromeMetrics.LinkChip.cornerRadius)
                        .fill(theme.accent.opacity(ChromeMetrics.LinkChip.flashOpacity))
                } else if isHovering {
                    HoverWashFill(theme: theme, cornerRadius: ChromeMetrics.LinkChip.cornerRadius)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("flock.pane.link.\(id)")
    }
}
