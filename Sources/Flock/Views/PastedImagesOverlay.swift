import FlockCore
import SwiftUI

private typealias Card = ChromeMetrics.ConfirmCard
private typealias M = ChromeMetrics.PastedImages

/// A pane's pasted images, drawn over its terminal: a chip in place of each
/// label, and a tray of the prompt's images above the prompt.
struct PastedImagesOverlay: View {
    let theme: Theme
    let model: PastedImagesModel
    let space: String
    let fontSizePoints: Double
    let shade: SurfaceShade
    /// False while the pane is being arranged, when nothing in it is for
    /// clicking.
    let showsTray: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { pane in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(model.labels.enumerated()), id: \.offset) { _, label in
                    if !label.isAttachmentLine, !label.isWrapped, let image = model.images[label.number] {
                        PastedImageChip(
                            theme: theme, label: label, image: image, fontSizePoints: fontSizePoints,
                            isLit: model.highlighted == label.number
                        )
                        // The surface's own dimming is under this view.
                        .saturation(1 - shade.drain)
                        .overlay(theme.terminalGround.opacity(shade.veil))
                        .offset(x: label.rect.minX, y: label.rect.minY)
                        // It moves with the text, which never animates.
                        .transaction { $0.animation = nil }
                    }
                }
                .allowsHitTesting(false)
                if showsTray, let top = model.promptTop, !model.promptNumbers.isEmpty {
                    PastedImageTray(
                        theme: theme, model: model, space: space,
                        numbers: model.promptNumbers,
                        available: CGSize(width: pane.size.width, height: top)
                    )
                    .frame(
                        width: max(0, pane.size.width - M.trayInset),
                        height: max(0, top - M.trayInset),
                        alignment: .bottomTrailing
                    )
                    .transition(
                        reduceMotion ? .opacity
                            : .opacity.combined(with: .offset(y: ChromeMetrics.LinkChip.fadeRise))
                    )
                }
            }
            .overlay {
                if let label = model.dropLabel {
                    PastedImageDropTarget(theme: theme, label: label).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: ChromeMetrics.LinkChip.fade), value: model.dropLabel)
            .animation(
                model.promptNumbers.isEmpty
                    ? .easeIn(duration: ChromeMetrics.LinkChip.fadeOut)
                    : .easeOut(duration: ChromeMetrics.LinkChip.fade),
                value: model.promptNumbers
            )
        }
    }
}

private struct PastedImageDropTarget: View {
    let theme: Theme
    let label: String

    var body: some View {
        let colors = theme.confirmCardColors
        ZStack {
            theme.terminalGround.opacity(M.dropDim)
            HStack(spacing: M.dropGap) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(ChromeType.pastedImageDropSymbol)
                    .foregroundStyle(Color(colors.body))
                Text(label)
                    .font(ChromeType.confirmCardTitle)
                    .foregroundStyle(Color(colors.title))
            }
            .padding(.horizontal, M.dropPadding.width)
            .padding(.vertical, M.dropPadding.height)
            .confirmCardSurface(theme)
        }
        .accessibilityIdentifier("flock.pane.dropTarget")
        .allowsHitTesting(false)
    }
}

/// `[Image #N]` in the same cells: the text in the terminal's own font, a
/// step smaller, so the cells it frees pad the ends.
private struct PastedImageChip: View {
    let theme: Theme
    let label: PastedImagesModel.Label
    let image: PastedImage
    let fontSizePoints: Double
    let isLit: Bool

    var body: some View {
        let cell = label.rect.width / CGFloat("[Image #\(label.number)]".count)
        let height = label.rect.height - M.chipRowInset * 2
        HStack(spacing: 0) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: cell * M.chipImageCells, height: height)
                .clipped()
            Text("Image \(label.number)")
                .font(.custom(TerminalFont.face, fixedSize: fontSizePoints * M.chipTextScale))
                .foregroundStyle(Color(theme.confirmCardColors.title))
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        // Short of its last cell, since text can follow with no space.
        .frame(width: label.rect.width - cell * M.chipMarginCells, height: height)
        .background {
            Color(theme.confirmCardColors.ground)
            theme.accent.opacity(isLit ? M.chipLitOpacity : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: M.chipCornerRadius))
        .frame(width: label.rect.width, height: label.rect.height, alignment: .leading)
        // The row's own color over the program's label, then the chip.
        .background(ground)
    }

    private var ground: Color {
        guard let ground = label.ground else { return theme.terminalGround }
        return Color(
            .displayP3, red: Double(ground.red) / 255, green: Double(ground.green) / 255,
            blue: Double(ground.blue) / 255)
    }
}

/// The images in the prompt: a strip that grows leftward until
/// `stripWidth`, then pages.
private struct PastedImageTray: View {
    let theme: Theme
    let model: PastedImagesModel
    let space: String
    let numbers: [Int]
    let available: CGSize

    @State private var position = ScrollPosition(edge: .trailing)
    @State private var offset: CGFloat = 0
    @State private var pointerInside = false
    @State private var id = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(M.cardPadding)
            .confirmCardSurface(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flock.pane.imageTray")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { model.trayMoved(id, to: $0) }
            .onHover { pointerInside = $0 }
            .onDisappear { model.trayWent(id) }
            .onChange(of: numbers) { old, new in
                guard new.count > old.count else { return }
                withAnimation(motion) { position.scrollTo(edge: .trailing) }
            }
            .onChange(of: model.highlighted) { _, number in
                guard let number, numbers.contains(number), !pointerInside else { return }
                guard let index = numbers.firstIndex(of: number), let x = row.revealing(index) else { return }
                scroll(to: x)
            }
    }

    private var content: some View {
        VStack(spacing: M.footerGap) {
            strip
            if row.overflow > 0 { footer }
        }
    }

    private var colors: Card.Colors { theme.confirmCardColors }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: M.pageDuration) }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: M.thumbGap) {
                ForEach(numbers, id: \.self) { number in
                    thumb(number, size: CGSize(width: thumbWidth(number), height: thumbHeight))
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        .frame(width: row.viewport, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.control))
    }

    @ViewBuilder
    private func thumb(_ number: Int, size: CGSize) -> some View {
        if let image = model.images[number] {
            PastedImageThumb(
                theme: theme, number: number, image: image, size: size,
                isLit: model.highlighted == number,
                onHover: { hover(number, $0) },
                onQuickLook: { model.quickLook(number, from: .tray) },
                onOpen: { model.open(number) }
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { model.thumbFrames[number] = $0 }
            .transition(.opacity)
        }
    }

    private var thumbHeight: CGFloat {
        let around = M.trayInset * 2 + M.cardPadding * 2 + M.footerGap + M.footerHeight
        return max(M.minimumThumbHeight, min(M.thumbHeight, available.height - around))
    }

    private func thumbWidth(_ number: Int) -> CGFloat {
        guard let size = model.images[number]?.thumbnail.size, size.height > 0 else { return M.thumbWidths.lowerBound }
        let scale = thumbHeight / M.thumbHeight
        let width = thumbHeight * size.width / size.height
        return min(max(width, M.thumbWidths.lowerBound * scale), M.thumbWidths.upperBound * scale)
    }

    private var row: PastedImageStrip {
        let widths = numbers.map(thumbWidth)
        let content = widths.reduce(0, +) + M.thumbGap * CGFloat(max(0, widths.count - 1))
        let room = available.width - M.trayInset * 2 - M.cardPadding * 2
        return PastedImageStrip(
            widths: widths, gap: M.thumbGap,
            viewport: max(M.minimumStripWidth, min(content, M.stripWidth, room)), offset: offset
        )
    }

    private func scroll(to x: CGFloat) {
        withAnimation(motion) { position.scrollTo(x: x) }
    }

    // MARK: Pager

    private var footer: some View {
        let row = row
        return HStack(spacing: M.thumbGap) {
            Text("\(numbers.count) images")
                .font(ChromeType.confirmCardName)
                .foregroundStyle(Color(colors.title))
            if let shown = row.shown {
                Text(shown.count == 1 ? "\(shown.lowerBound)" : "\(shown.lowerBound) to \(shown.upperBound)")
                    .font(ChromeType.confirmCardMessage)
                    .monospacedDigit()
                    .foregroundStyle(Color(colors.body))
            }
            Spacer(minLength: 0)
            HStack(spacing: M.buttonGap) {
                PastedImagePager(theme: theme, forward: false, isEnabled: row.canPageBack) { scroll(to: row.previousPage) }
                PastedImagePager(theme: theme, forward: true, isEnabled: row.canPageForward) { scroll(to: row.nextPage) }
            }
        }
        .lineLimit(1)
        .padding(.leading, M.footerLeading)
        .frame(width: row.viewport, height: M.footerHeight)
    }

    private func hover(_ number: Int, _ inside: Bool) {
        if inside {
            model.highlight(number)
        } else if model.highlighted == number {
            model.highlight(nil)
        }
    }
}

/// A quiet button in the confirm card's fills.
private struct PastedImagePager: View {
    let theme: Theme
    let forward: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(ChromeType.pastedImagePagerSymbol)
                .foregroundStyle(Color(theme.confirmCardColors.title))
                .frame(width: M.pagerWidth, height: M.footerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(Style(edge: Color(theme.confirmCardColors.edge), isHovering: isHovering && isEnabled))
        .opacity(isEnabled ? 1 : M.disabledOpacity)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .pointerStyle(isEnabled ? .link : nil)
        .onHover { isHovering = $0 }
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isHovering)
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isEnabled)
        .accessibilityLabel(forward ? "Next images" : "Previous images")
        .accessibilityIdentifier(forward ? "flock.pane.imageTray.next" : "flock.pane.imageTray.previous")
    }

    private struct Style: ButtonStyle {
        let edge: Color
        let isHovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background(
                RoundedRectangle(cornerRadius: Card.buttonCornerRadius)
                    .fill(edge.opacity(
                        configuration.isPressed ? Card.quietPressedFillOpacity
                            : isHovering ? M.hoverFillOpacity : Card.quietFillOpacity))
            )
        }
    }
}

private struct PastedImageThumb: View {
    let theme: Theme
    let number: Int
    let image: PastedImage
    let size: CGSize
    /// The pointer is on this image, here or on its label in the terminal.
    let isLit: Bool
    let onHover: (Bool) -> Void
    let onQuickLook: () -> Void
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onQuickLook) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(Style(theme: theme, number: number, isLit: isLit))
        .focusEffectDisabled()
        .pointerStyle(.link)
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isLit)
        .onHover(perform: onHover)
        .contextMenu {
            Button("Quick Look", action: onQuickLook)
            Button("Open", action: onOpen)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([image.url])
            }
            Button("Copy Image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image.url as NSURL])
            }
        }
        .accessibilityLabel("Image \(number)")
        .accessibilityIdentifier("flock.pane.imageTray.image.\(number)")
    }

    private struct Style: ButtonStyle {
        let theme: Theme
        let number: Int
        let isLit: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: ChromeRadius.control)
            let colors = theme.confirmCardColors
            let edge = Color(colors.edge).opacity(colors.edgeOpacity)
            configuration.label
                .overlay { if configuration.isPressed { Color.black.opacity(M.pressedDim) } }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(isLit ? theme.accent : edge, lineWidth: isLit ? M.litBorderWidth : ChromeMetrics.ruleWidth)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(number)")
                        .font(ChromeType.linkChip)
                        .foregroundStyle(isLit ? theme.chrome : Color(colors.title))
                        .padding(.horizontal, M.badgeInset)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isLit ? theme.accent : Color(colors.ground)))
                        .padding(M.badgePadding)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? M.pressedScale : 1)
                .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// The card over a hovered label: the image, and the tray's footer.
struct PastedImagePreview: View {
    let theme: Theme
    let number: Int
    let image: NSImage
    let limit: CGSize
    let flash: LinkChip.Action?
    let onQuickLook: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void

    /// The image's size, with room left for the rest of the card.
    static func limit(for anchor: LinkChip.Anchor, in pane: CGSize) -> CGSize {
        let room = max(anchor.lineTop, pane.height - anchor.lineBottom)
        return CGSize(
            width: min(M.previewLimit.width, pane.width - M.previewReserve.width),
            height: min(M.previewLimit.height, room - M.previewReserve.height)
        )
    }

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = theme.confirmCardColors
        let inner = RoundedRectangle(cornerRadius: ChromeRadius.control)
        let size = fitted
        let width = max(size.width, M.previewMinimumWidth)
        VStack(spacing: M.cardPadding) {
            Button(action: onQuickLook) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .frame(width: width)
                    .background(Color(colors.edge).opacity(Card.quietFillOpacity))
                    .clipShape(inner)
                    .overlay {
                        inner.strokeBorder(
                            isHovering ? theme.accent : Color(colors.edge).opacity(colors.edgeOpacity),
                            lineWidth: isHovering ? M.litBorderWidth : ChromeMetrics.ruleWidth)
                    }
                    .contentShape(inner)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { isHovering = $0 }
            .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isHovering)
            HStack(spacing: M.buttonGap) {
                Text("Image \(number)")
                    .font(ChromeType.confirmCardName)
                    .foregroundStyle(Color(colors.title))
                    .padding(.leading, M.footerLeading)
                Spacer(minLength: M.footerGap)
                PastedImageCardButton(theme: theme, title: "Reveal", isLit: flash == .second, action: onReveal)
                PastedImageCardButton(theme: theme, title: "Open", isLit: flash == .open, action: onOpen)
            }
            .frame(width: width)
        }
        .padding(M.cardPadding)
        .confirmCardSurface(theme)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.pane.imagePreview")
    }

    private var fitted: CGSize {
        let width = max(40, limit.width), height = max(40, limit.height)
        let scale = min(1, width / max(1, image.size.width), height / max(1, image.size.height))
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}

private struct PastedImageCardButton: View {
    let theme: Theme
    let title: String
    /// Says, for the moment before the card goes, that this was the action.
    let isLit: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(title, action: action)
            .buttonStyle(Style(theme: theme, isHovering: isHovering, isLit: isLit))
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { isHovering = $0 }
            .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isHovering)
    }

    private struct Style: ButtonStyle {
        let theme: Theme
        let isHovering: Bool
        let isLit: Bool

        func makeBody(configuration: Configuration) -> some View {
            let edge = Color(theme.confirmCardColors.edge)
            configuration.label
                .font(ChromeType.confirmCardButton)
                .foregroundStyle(Color(theme.confirmCardColors.title))
                .padding(.horizontal, M.buttonPadding)
                .frame(height: Card.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: Card.buttonCornerRadius)
                        .fill(isLit ? theme.accent.opacity(ChromeMetrics.LinkChip.flashOpacity)
                            : edge.opacity(
                                configuration.isPressed ? Card.quietPressedFillOpacity
                                    : isHovering ? M.hoverFillOpacity : Card.quietFillOpacity))
                )
                .contentShape(Rectangle())
        }
    }
}
