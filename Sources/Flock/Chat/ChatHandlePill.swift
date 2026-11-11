import FlockCore
import SwiftUI

/// A signed-in pane's chat identity: its name and face, with a dot on the
/// face for unread. The pane's chat button draws it as its label; Overview and
/// Arrange draw it as a plain mark. Always a key, where the bar's other
/// buttons are bare until hovered: it says who is in the pane.
struct ChatHandlePill: View {
    let theme: Theme
    let name: String
    let handle: String?
    let unread: Int
    var isHovered = false

    @Environment(ChatStore.self) private var chatStore: ChatStore?

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        let style = LauncherStripStyle(theme: theme)
        let state: LauncherStripStyle.KeyState = isHovered ? .hovered : .rest
        let shape = RoundedRectangle(cornerRadius: M.chipCornerRadius, style: .continuous)
        HStack(spacing: M.chipNameGap) {
            // `fixedSize` as well as no width: a name is never shortened, so
            // it has to refuse to compress even when its row runs out of
            // room. What gives instead is whatever shares the row.
            Text(name)
                .font(ChromeType.chatButtonHandle)
                .foregroundStyle(style.text(state))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ChatFace(style: style, name: name, image: handle.flatMap { chatStore?.face(for: $0) })
                .overlay(alignment: .topTrailing) {
                    if unread > 0 { ChatUnreadDot(theme: theme) }
                }
        }
        .padding(.leading, M.chipNameGap)
        .padding(.trailing, M.chipFaceInset)
        .frame(height: M.chipHeight)
        .background(shape.fill(style.keyFill(state)))
        .overlay(shape.strokeBorder(style.keyEdge(state), lineWidth: 1))
        .contentShape(shape)
        .task(id: handle) {
            guard let handle else { return }
            await chatStore?.followFace(handle)
        }
    }
}

/// The face rt hands over, or the name's initial until one arrives. An rt
/// without faces stays on the initial.
struct ChatFace: View {
    let style: LauncherStripStyle
    let name: String
    let image: ChatFaceImage?

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: M.faceCornerRadius, style: .continuous)
        if let image {
            Image(decorative: image.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: M.faceSize, height: M.faceSize)
                .scaleEffect(image.zoom)
                .clipShape(shape)
        } else {
            Text(name.prefix(1).uppercased())
                .font(ChromeType.paneBarFaceInitial)
                .foregroundStyle(style.text(.rest))
                .frame(width: M.faceSize, height: M.faceSize)
                .background(shape.fill(style.keyFill(.hovered)))
        }
    }
}

/// Sits on the face's corner, ringed in the pane's ground so it reads as cut
/// out of the face. No number: the count lives in the popover's Peek.
private struct ChatUnreadDot: View {
    let theme: Theme

    private typealias M = ChromeMetrics.PaneBar

    var body: some View {
        Circle()
            .fill(theme.red)
            .frame(width: M.unreadDotSize, height: M.unreadDotSize)
            .padding(M.unreadDotRing)
            .background(Circle().fill(theme.terminalGround))
            .offset(x: M.unreadDotOverhang + M.unreadDotRing, y: -(M.unreadDotOverhang + M.unreadDotRing))
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
