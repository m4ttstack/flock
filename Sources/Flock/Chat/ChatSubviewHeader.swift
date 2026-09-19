import FlockCore
import SwiftUI

/// The back-chevron / title / close band every chat sub-view opens with
/// (Peek, Quick send, Broadcast), parameterized only by width -- Broadcast
/// draws wider than the other two, and nothing else about this band changes
/// between them. Carries the same bottom rule the main popover's header and
/// status bands carry.
struct ChatSubviewHeader: View {
    let theme: Theme
    let title: String
    let width: CGFloat
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: ChromeMetrics.ChatSubviewHeader.gap) {
            iconButton("chevron.left", action: onBack)
            Text(title)
                .font(ChromeType.chatPopoverTitle)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
            iconButton("xmark", action: onClose)
        }
        .padding(.vertical, ChromeMetrics.ChatSubviewHeader.verticalPadding)
        .padding(.horizontal, ChromeMetrics.ChatSubviewHeader.horizontalPadding)
        .frame(width: width, height: ChromeMetrics.ChatSubviewHeader.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(theme.palette.surface0)).frame(height: 1)
        }
    }

    /// Font-sized, not `.resizable().scaledToFit()`: that path force-scales
    /// each symbol's own outline into the box, and `xmark`'s outline fills
    /// far more of a square box than `chevron.left`'s does, so the two read
    /// at different weights even under the identical `overlay0` colour. A
    /// point-size font lets each symbol use its own optical sizing instead.
    private func iconButton(_ symbolName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: ChromeMetrics.ChatSubviewHeader.iconSize.width, weight: .regular))
                .foregroundStyle(theme.overlay0)
                .frame(width: ChromeMetrics.ChatSubviewHeader.iconSize.width, height: ChromeMetrics.ChatSubviewHeader.iconSize.height)
        }
        .buttonStyle(.plain)
    }
}
