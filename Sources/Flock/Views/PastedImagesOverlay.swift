import FlockCore
import SwiftUI

/// SPIKE: a pane's pasted images, drawn over its terminal as chips in place
/// of their labels and a tray over the prompt. The preview is the link
/// chip's (`LinkChipView`).
struct PastedImagesOverlay: View {
    let theme: Theme
    let model: PastedImagesModel
    let space: String
    let fontSizePoints: Double
    let shade: SurfaceShade

    @AppStorage(PastedImageOptions.trayKey) private var showsTray = true
    @AppStorage(PastedImageOptions.chipKey) private var showsChips = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { pane in
            ZStack(alignment: .topLeading) {
                Color.clear
                if showsChips {
                    ForEach(Array(model.labels.enumerated()), id: \.offset) { _, label in
                        if !label.isAttachmentLine, let image = model.images[label.number] {
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
                }
                if showsTray, let top = model.promptTop, !trayNumbers.isEmpty {
                    PastedImageTray(
                        theme: theme, model: model, space: space,
                        numbers: trayNumbers,
                        available: CGSize(width: pane.size.width, height: top)
                    )
                    .frame(
                        width: max(0, pane.size.width - PastedImageTray.inset),
                        height: max(0, top - PastedImageTray.inset),
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
                trayNumbers.isEmpty
                    ? .easeIn(duration: ChromeMetrics.LinkChip.fadeOut)
                    : .easeOut(duration: ChromeMetrics.LinkChip.fade),
                value: trayNumbers
            )
        }
    }

    private var trayNumbers: [Int] {
        Set(model.labels.filter { $0.inPrompt && model.images[$0.number] != nil }.map(\.number)).sorted()
    }
}

private typealias Card = ChromeMetrics.ConfirmCard

private extension Theme {
    /// The confirm card's colors, in the scheme opposite the window's.
    var cardColors: Card.Colors { ChromeRoles.isLight(panelBg: palette.panelBg) ? .dark : .light }
}

private struct PastedImageDropTarget: View {
    let theme: Theme
    let label: String

    var body: some View {
        let colors = theme.cardColors
        let card = RoundedRectangle(cornerRadius: Card.cornerRadius)
        ZStack {
            theme.terminalGround.opacity(0.62)
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(colors.body))
                Text(label)
                    .font(ChromeType.confirmCardTitle)
                    .foregroundStyle(Color(colors.title))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background {
                card.fill(Color(colors.ground))
                    .shadow(color: .black.opacity(Card.contactShadowOpacity), radius: Card.contactShadowRadius, y: Card.contactShadowY)
                    .shadow(color: .black.opacity(Card.liftShadowOpacity), radius: Card.liftShadowRadius, y: Card.liftShadowY)
            }
            .overlay(card.strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: ChromeMetrics.ruleWidth))
        }
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
        let height = label.rect.height - 2
        HStack(spacing: 0) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: cell * 2.2, height: height)
                .clipped()
            Text("Image \(label.number)")
                .font(.custom(TerminalFont.face, fixedSize: fontSizePoints * 0.82))
                .foregroundStyle(Color(theme.cardColors.title))
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        // Short of its last cell, since text can follow with no space.
        .frame(width: label.rect.width - cell * 0.55, height: height)
        .background {
            Color(theme.cardColors.ground)
            theme.accent.opacity(isLit ? 0.35 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(width: label.rect.width, height: label.rect.height, alignment: .leading)
        // The row's own color over the program's label, then the chip.
        .background(ground)
    }
}

private extension PastedImageChip {
    var ground: Color {
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

    static let inset: CGFloat = 12
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let thumbHeight: CGFloat = 128
    private static let thumbWidths: ClosedRange<CGFloat> = 80...228
    private static let stripWidth: CGFloat = 640
    private static let footerGap: CGFloat = 10
    private static let footerHeight: CGFloat = 28
    @State private var position = ScrollPosition(edge: .trailing)
    @State private var offset: CGFloat = 0
    @State private var pointerInside = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(Self.padding)
            .background {
                shape.fill(Color(colors.ground))
                    .shadow(color: .black.opacity(Card.contactShadowOpacity), radius: Card.contactShadowRadius, y: Card.contactShadowY)
                    .shadow(color: .black.opacity(Card.liftShadowOpacity), radius: Card.liftShadowRadius, y: Card.liftShadowY)
            }
            .overlay {
                shape.strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: ChromeMetrics.ruleWidth)
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { model.trayFrame = $0 }
            .onHover { pointerInside = $0 }
            .onDisappear { model.trayFrame = nil }
            .onChange(of: numbers) { old, new in
                guard new.count > old.count else { return }
                withAnimation(motion) { position.scrollTo(edge: .trailing) }
            }
            .onChange(of: model.highlighted) { _, number in
                guard let number, numbers.contains(number), !pointerInside else { return }
                reveal(number)
            }
    }

    private var content: some View {
        VStack(spacing: Self.footerGap) {
            strip
            if overflow > 0 { footer }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Card.cornerRadius) }
    private var colors: Card.Colors { theme.cardColors }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.22) }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.gap) {
                ForEach(numbers, id: \.self) { number in
                    thumb(number, size: CGSize(width: thumbWidth(number), height: thumbHeight))
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        .frame(width: viewport, height: thumbHeight)
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
        let extra = Self.footerGap + Self.footerHeight
        return max(32, min(Self.thumbHeight, available.height - Self.inset * 2 - Self.padding * 2 - extra))
    }

    private func thumbWidth(_ number: Int) -> CGFloat {
        guard let size = model.images[number]?.thumbnail.size, size.height > 0 else { return Self.thumbWidths.lowerBound }
        let scale = thumbHeight / Self.thumbHeight
        let width = thumbHeight * size.width / size.height
        return min(max(width, Self.thumbWidths.lowerBound * scale), Self.thumbWidths.upperBound * scale)
    }

    /// Each thumbnail's span in the scrolled content.
    private var spans: [(number: Int, range: ClosedRange<CGFloat>)] {
        var x: CGFloat = 0
        return numbers.map { number in
            let start = x
            x += thumbWidth(number) + Self.gap
            return (number, start...(x - Self.gap))
        }
    }

    private var contentWidth: CGFloat { spans.last?.range.upperBound ?? 0 }

    private var viewport: CGFloat {
        max(60, min(contentWidth, Self.stripWidth, available.width - Self.inset * 2 - Self.padding * 2))
    }

    private var overflow: CGFloat { max(0, contentWidth - viewport) }

    /// The thumbnails at least half in view, counted from 1.
    private var shownRange: ClosedRange<Int>? {
        let shown = spans.indices.filter {
            let span = spans[$0].range
            let visible = min(span.upperBound, offset + viewport) - max(span.lowerBound, offset)
            return visible >= (span.upperBound - span.lowerBound) / 2
        }
        guard let first = shown.first, let last = shown.last else { return nil }
        return (first + 1)...(last + 1)
    }

    private func scroll(to x: CGFloat) {
        withAnimation(motion) { position.scrollTo(x: min(max(0, x), overflow)) }
    }

    /// Starts the next page on the first thumbnail this one cuts off, and
    /// ends the previous page on the last one it does.
    private func page(forward: Bool) {
        if forward {
            let next = spans.first { $0.range.upperBound > offset + viewport + 1 }?.range.lowerBound ?? overflow
            scroll(to: next > offset + 1 ? next : offset + viewport)
        } else {
            let previous = spans.last { $0.range.lowerBound < offset - 1 }?.range.upperBound ?? 0
            scroll(to: previous < offset + viewport - 1 ? previous - viewport : offset - viewport)
        }
    }

    private func reveal(_ number: Int) {
        guard overflow > 0, let span = spans.first(where: { $0.number == number })?.range else { return }
        if span.lowerBound < offset {
            scroll(to: span.lowerBound)
        } else if span.upperBound > offset + viewport {
            scroll(to: span.upperBound - viewport)
        }
    }

    // MARK: Pager

    private var footer: some View {
        HStack(spacing: Self.gap) {
            Text("\(numbers.count) images")
                .font(ChromeType.confirmCardName)
                .foregroundStyle(Color(colors.title))
            if let shown = shownRange {
                Text(shown.count == 1 ? "\(shown.lowerBound)" : "\(shown.lowerBound) to \(shown.upperBound)")
                    .font(ChromeType.confirmCardMessage)
                    .monospacedDigit()
                    .foregroundStyle(Color(colors.body))
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                pager(forward: false, width: 34, height: Self.footerHeight)
                pager(forward: true, width: 34, height: Self.footerHeight)
            }
        }
        .padding(.leading, 4)
        .frame(width: viewport, height: Self.footerHeight)
    }

    private func pager(forward: Bool, width: CGFloat, height: CGFloat) -> some View {
        PastedImagePager(
            theme: theme, forward: forward, size: CGSize(width: width, height: height),
            isEnabled: forward ? offset < overflow - 1 : offset > 1
        ) { page(forward: forward) }
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
    let size: CGSize
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(theme.cardColors.title))
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(Style(edge: Color(theme.cardColors.edge), isHovering: isHovering && isEnabled))
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .pointerStyle(isEnabled ? .link : nil)
        .onHover { isHovering = $0 }
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isHovering)
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isEnabled)
        .accessibilityLabel(forward ? "Next images" : "Previous images")
    }

    private struct Style: ButtonStyle {
        let edge: Color
        let isHovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background(
                RoundedRectangle(cornerRadius: Card.buttonCornerRadius)
                    .fill(edge.opacity(
                        configuration.isPressed ? Card.quietPressedFillOpacity
                            : isHovering ? 0.11 : Card.quietFillOpacity))
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
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.path)])
            }
            Button("Copy Image") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([URL(fileURLWithPath: image.path) as NSURL])
            }
        }
        .accessibilityLabel("Image \(number)")
    }

    private struct Style: ButtonStyle {
        let theme: Theme
        let number: Int
        let isLit: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: ChromeRadius.control)
            let colors = theme.cardColors
            let edge = Color(colors.edge).opacity(colors.edgeOpacity)
            configuration.label
                .overlay { if configuration.isPressed { Color.black.opacity(0.18) } }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(isLit ? theme.accent : edge, lineWidth: isLit ? 2 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(number)")
                        .font(ChromeType.linkChip)
                        .foregroundStyle(isLit ? theme.chrome : Color(colors.title))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isLit ? theme.accent : Color(colors.ground)))
                        .padding(5)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
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

    private static let padding: CGFloat = 8
    private static let minimumWidth: CGFloat = 264

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = theme.cardColors
        let card = RoundedRectangle(cornerRadius: Card.cornerRadius)
        let inner = RoundedRectangle(cornerRadius: ChromeRadius.control)
        let size = fitted
        VStack(spacing: Self.padding) {
            Button(action: onQuickLook) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .frame(width: max(size.width, Self.minimumWidth))
                    .background(Color(colors.edge).opacity(Card.quietFillOpacity))
                    .clipShape(inner)
                    .overlay {
                        inner.strokeBorder(
                            isHovering ? theme.accent : Color(colors.edge).opacity(colors.edgeOpacity),
                            lineWidth: isHovering ? 2 : 1)
                    }
                    .contentShape(inner)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { isHovering = $0 }
            .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isHovering)
            HStack(spacing: 4) {
                Text("Image \(number)")
                    .font(ChromeType.confirmCardName)
                    .foregroundStyle(Color(colors.title))
                    .padding(.leading, 4)
                Spacer(minLength: 12)
                PastedImageCardButton(theme: theme, title: "Reveal", isLit: flash == .second, action: onReveal)
                PastedImageCardButton(theme: theme, title: "Open", isLit: flash == .open, action: onOpen)
            }
            .frame(width: max(size.width, Self.minimumWidth))
        }
        .padding(Self.padding)
        .background {
            card.fill(Color(colors.ground))
                .shadow(color: .black.opacity(Card.contactShadowOpacity), radius: Card.contactShadowRadius, y: Card.contactShadowY)
                .shadow(color: .black.opacity(Card.liftShadowOpacity), radius: Card.liftShadowRadius, y: Card.liftShadowY)
        }
        .overlay {
            card.strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: ChromeMetrics.ruleWidth)
                .allowsHitTesting(false)
        }
        .fixedSize()
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
            let edge = Color(theme.cardColors.edge)
            configuration.label
                .font(ChromeType.confirmCardButton)
                .foregroundStyle(Color(theme.cardColors.title))
                .padding(.horizontal, 12)
                .frame(height: Card.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: Card.buttonCornerRadius)
                        .fill(isLit ? theme.accent.opacity(ChromeMetrics.LinkChip.flashOpacity)
                            : edge.opacity(
                                configuration.isPressed ? Card.quietPressedFillOpacity
                                    : isHovering ? 0.11 : Card.quietFillOpacity))
                )
                .contentShape(Rectangle())
        }
    }
}

/// SPIKE: the Pane menu's switches for each treatment.
struct PastedImageMenu: View {
    @AppStorage(PastedImageOptions.trayKey) private var showsTray = true
    @AppStorage(PastedImageOptions.hoverKey) private var showsHover = true
    @AppStorage(PastedImageOptions.chipKey) private var showsChips = true

    var body: some View {
        Menu("Pasted Images (spike)") {
            Toggle("Thumbnail Tray", isOn: $showsTray)
            Toggle("Hover Preview, Click to Open", isOn: $showsHover)
            Toggle("Label as Chip", isOn: $showsChips)
        }
    }
}
