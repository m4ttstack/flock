import FlockCore
import SwiftUI

/// A signed-in pane's chat identity: its name, the bubble, and an unread
/// count when there is one. The pane's chat button draws it as its label;
/// Overview and Arrange draw it as a plain mark.
struct ChatHandlePill: View {
    let theme: Theme
    let name: String
    let unread: Int

    private typealias C = ChromeMetrics.ChatButton

    var body: some View {
        HStack(spacing: C.gap) {
            // `fixedSize` as well as no width: a name is never shortened, so
            // it has to refuse to compress even when its row runs out of
            // room. What gives instead is whatever shares the row.
            Text(name)
                .font(ChromeType.chatButtonHandle)
                .foregroundStyle(theme.green)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: C.handleHeight, alignment: .leading)
            ChatGlyph(color: theme.green)
                .frame(width: C.iconSize.width, height: C.iconSize.height)
            if unread > 0 {
                Text("\(unread)")
                    .font(ChromeType.chatButtonHandle)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: C.countHeight, alignment: .leading)
            }
        }
        .padding(.vertical, C.verticalPadding)
        .padding(.horizontal, C.horizontalPadding)
        .frame(height: C.signedInHeight)
        .background(RoundedRectangle(cornerRadius: C.cornerRadius).fill(Color(theme.palette.selectionBg)))
    }
}

/// `bubble.left.fill` sized to its own measured box rather than a point
/// size, so the rendered glyph matches the design's icon box exactly.
struct ChatGlyph: View {
    let color: Color

    var body: some View {
        Image(systemName: "bubble.left.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }
}

extension ChatStore {
    /// Who a pane is signed in as, from the last peek. Nil on a machine
    /// without chat, and for a pane that is not signed in.
    func signedInBuddy(_ pane: PaneID) -> ChatBuddy? {
        isAvailable ? buddies[pane] : nil
    }
}
