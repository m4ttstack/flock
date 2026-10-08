import FlockCore
import SwiftUI

/// A modal over the area it is mounted on: a backdrop that dims it and
/// dismisses on a click, and centred on it a card sized by `ModalSize`,
/// holding a title row (the caller's leading content, the size control and
/// a close control), the caller's content, and an optional footer.
struct ChromeModal<Leading: View, Content: View, Footer: View>: View {
    let theme: Theme
    let size: ModalSize
    var footerHeight: CGFloat = 0
    /// Where the card is centred and sized, in the backdrop's own space; the
    /// whole backdrop when nil.
    var cardArea: CGRect? = nil
    let onSize: (ModalSize) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: (_ area: CGSize, _ scale: CGFloat) -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(\.displayScale) private var displayScale

    private typealias Metrics = ChromeMetrics.Modal

    var body: some View {
        GeometryReader { proxy in
            let scale = displayScale > 0 ? displayScale : 2
            let global = proxy.frame(in: .global).origin
            let area = cardArea ?? CGRect(origin: .zero, size: proxy.size)
            let frame = Self.boxFrame(
                in: area.size, origin: CGPoint(x: global.x + area.minX, y: global.y + area.minY), scale: scale,
                fraction: Metrics.sizeFraction(size)
            ).offsetBy(dx: area.minX, dy: area.minY)
            ZStack(alignment: .topLeading) {
                backdrop
                card(size: frame.size, scale: scale)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    /// Both edges of each axis are snapped where they land in the window, as
    /// `CanvasGrid` snaps a pane box: the pane inside sits a whole number of
    /// points in from them, so ghostty composites it on whole device pixels.
    static func boxFrame(in area: CGSize, origin: CGPoint, scale: CGFloat, fraction: CGFloat) -> CGRect {
        let grid = CanvasGrid(canvas: area, phase: origin, displayScale: scale)
        let margin = (1 - fraction) / 2
        let left = grid.snappedX(area.width * margin)
        let right = grid.snappedX(area.width * (1 - margin))
        let top = grid.snappedY(area.height * margin)
        let bottom = grid.snappedY(area.height * (1 - margin))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private var backdrop: some View {
        let isLight = ChromeRoles.isLight(panelBg: theme.palette.panelBg)
        return Color.black
            .opacity(isLight ? Metrics.lightBackdropOpacity : Metrics.darkBackdropOpacity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
    }

    private func card(size boxSize: CGSize, scale: CGFloat) -> some View {
        let area = CGSize(
            width: max(0, boxSize.width - 2 * Metrics.paneInset),
            height: max(0, boxSize.height - Metrics.TitleRow.height - footerHeight - 2 * Metrics.paneInset)
        )
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        return VStack(spacing: 0) {
            ModalTitleRow(theme: theme, size: size, onSize: onSize, onClose: onDismiss, leading: leading)
            content(area, scale)
                .frame(width: area.width, height: area.height)
                .padding(Metrics.paneInset)
            footer()
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .top)
        .background(theme.pane)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.paneBorder, lineWidth: ChromeMetrics.ruleWidth))
        // Cast by a shape behind the card rather than by the card itself,
        // which would pull the terminal's surface through an offscreen pass.
        .background {
            shape
                .fill(theme.pane)
                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        }
    }
}

extension ChromeModal where Footer == EmptyView {
    init(
        theme: Theme, size: ModalSize, cardArea: CGRect? = nil, onSize: @escaping (ModalSize) -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder content: @escaping (_ area: CGSize, _ scale: CGFloat) -> Content
    ) {
        self.init(
            theme: theme, size: size, cardArea: cardArea, onSize: onSize, onDismiss: onDismiss,
            leading: leading, content: content, footer: { EmptyView() }
        )
    }
}

/// The caller's leading content, then the size control and the close
/// control at the trailing edge.
struct ModalTitleRow<Leading: View>: View {
    let theme: Theme
    let size: ModalSize
    let onSize: (ModalSize) -> Void
    let onClose: () -> Void
    @ViewBuilder let leading: () -> Leading

    private typealias Metrics = ChromeMetrics.Modal.TitleRow

    var body: some View {
        HStack(spacing: Metrics.gap) {
            leading()
            Spacer(minLength: 0)
            HStack(spacing: ChromeMetrics.Modal.SizeControl.gapBeforeClose) {
                ModalSizeControl(theme: theme, selected: size, onSelect: onSize)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(ChromeType.modalClose)
                        .foregroundStyle(theme.textDim)
                        .frame(width: Metrics.closeGlyphSize, height: Metrics.closeGlyphSize)
                        .hoverWash(theme, cornerRadius: Metrics.buttonCornerRadius)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("flock.modal.close")
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.height)
        .background(theme.chrome)
    }
}
