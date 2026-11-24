import FlockCore
import SwiftUI

/// SPIKE: a pane's pasted images, drawn over its terminal as chips in place
/// of their labels and a tray over the prompt. The preview is the link
/// chip's (`LinkChipView`).
struct PastedImagesOverlay: View {
    let theme: Theme
    let model: PastedImagesModel
    let linkChip: LinkChipModel
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
                        }
                    }
                    .allowsHitTesting(false)
                }
                if showsTray, let top = model.promptTop, !trayNumbers.isEmpty {
                    PastedImageTray(
                        theme: theme, model: model, linkChip: linkChip, space: space,
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
        HStack(spacing: 0) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: cell * 1.45, height: max(4, label.rect.height - 8))
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color(theme.cardColors.title).opacity(0.45), lineWidth: 1)
                }
                .padding(.leading, cell * 0.75)
            Spacer(minLength: 0)
            Text("Image \(label.number)")
                .font(.custom(TerminalFont.face, fixedSize: fontSizePoints * 0.85))
                .foregroundStyle(Color(theme.cardColors.title))
                .fixedSize()
                .padding(.trailing, cell * 0.8)
        }
        .frame(width: label.rect.width, height: label.rect.height)
        .background {
            // The row's own color over the program's label, then the chip.
            Rectangle().fill(ground)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(theme.cardColors.ground))
                .overlay(RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(isLit ? 0.35 : 0)))
                // Past its row by less than any glyph's own margin there.
                .padding(.vertical, -0.75)
        }
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
/// `stripWidth`, then pages, or a stage over a row of small thumbnails.
private struct PastedImageTray: View {
    let theme: Theme
    let model: PastedImagesModel
    let linkChip: LinkChipModel
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
    private static let gutterWidth: CGFloat = 28
    private static let trackGap: CGFloat = 8
    private static let trackHeight: CGFloat = 4
    private static let stage = CGSize(width: 328, height: 184)
    private static let miniHeight: CGFloat = 36
    private static let miniWidth: CGFloat = 37.5
    private static let miniGap: CGFloat = 4

    @AppStorage(PastedImageOptions.layoutKey) private var layout = PastedImageLayout.footer
    @State private var position = ScrollPosition(edge: .trailing)
    @State private var offset: CGFloat = 0
    @State private var pointerInside = false
    @State private var staged: Int?
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
                staged = new.last
                withAnimation(motion) { position.scrollTo(edge: .trailing) }
            }
            .onChange(of: model.highlighted) { _, number in
                guard let number, numbers.contains(number) else { return }
                if layout == .stage { staged = number }
                if !pointerInside { reveal(number) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .footer:
            VStack(spacing: Self.footerGap) {
                strip
                if overflow > 0 { footer }
            }
        case .gutters:
            VStack(spacing: Self.trackGap) {
                HStack(spacing: Self.gap) {
                    if overflow > 0 { pager(forward: false, width: Self.gutterWidth, height: thumbHeight) }
                    strip
                    if overflow > 0 { pager(forward: true, width: Self.gutterWidth, height: thumbHeight) }
                }
                if overflow > 0 { track }
            }
        case .stage:
            stageView
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
    private func thumb(_ number: Int, size: CGSize, badge: Bool = true) -> some View {
        if let image = model.images[number] {
            PastedImageThumb(
                theme: theme, number: number, image: image, size: size,
                isLit: model.highlighted == number, badge: badge, space: space,
                onHover: { frame in hover(number, image, frame) },
                onOpen: { model.open(number) }
            )
            .transition(.opacity)
        }
    }

    private var thumbHeight: CGFloat {
        let extra = layout == .footer ? Self.footerGap + Self.footerHeight : Self.trackGap + Self.trackHeight
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
        let gutters = layout == .gutters ? (Self.gutterWidth + Self.gap) * 2 : 0
        return max(60, min(contentWidth, Self.stripWidth, available.width - Self.inset * 2 - Self.padding * 2 - gutters))
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

    private var track: some View {
        GeometryReader { bar in
            let share = viewport / max(1, contentWidth)
            let width = bar.size.width * share
            let travel = bar.size.width - width
            Capsule().fill(Color(colors.edge).opacity(Card.quietFillOpacity))
            Capsule().fill(Color(colors.body))
                .frame(width: width)
                .offset(x: travel * min(1, max(0, offset / max(1, overflow))))
        }
        .frame(width: viewport + (Self.gutterWidth + Self.gap) * 2, height: Self.trackHeight)
    }

    private func pager(forward: Bool, width: CGFloat, height: CGFloat) -> some View {
        PastedImagePager(
            theme: theme, forward: forward, size: CGSize(width: width, height: height),
            isEnabled: forward ? offset < overflow - 1 : offset > 1
        ) { page(forward: forward) }
    }

    // MARK: Stage

    @ViewBuilder
    private var stageView: some View {
        let number = staged.flatMap { numbers.contains($0) ? $0 : nil } ?? numbers.last
        let scale = min(1, (available.width - Self.inset * 2 - Self.padding * 2) / Self.stage.width,
                        max(0.3, (available.height - Self.inset * 2 - Self.padding * 2 - Self.miniHeight - 8) / Self.stage.height))
        let size = CGSize(width: Self.stage.width * scale, height: Self.stage.height * scale)
        VStack(spacing: 8) {
            if let number, let image = model.images[number] {
                Button { model.open(number) } label: {
                    Image(nsImage: image.thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .background(Color(colors.edge).opacity(Card.quietFillOpacity))
                        .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.control))
                        .overlay {
                            RoundedRectangle(cornerRadius: ChromeRadius.control)
                                .strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.miniGap) {
                    ForEach(numbers, id: \.self) { number in
                        if let image = model.images[number] {
                            PastedImageThumb(
                                theme: theme, number: number, image: image,
                                size: CGSize(width: Self.miniWidth, height: Self.miniHeight),
                                isLit: number == (staged ?? numbers.last), badge: false, space: space,
                                onHover: { frame in
                                    if frame != nil {
                                        staged = number
                                        model.highlight(number)
                                    } else if model.highlighted == number {
                                        model.highlight(nil)
                                    }
                                },
                                onOpen: { model.open(number) }
                            )
                        }
                    }
                }
            }
            .frame(width: size.width, height: Self.miniHeight)
            .clipShape(RoundedRectangle(cornerRadius: ChromeRadius.control))
        }
    }

    private func hover(_ number: Int, _ image: PastedImage, _ frame: CGRect?) {
        guard let frame else {
            guard model.highlighted == number else { return }
            model.highlight(nil)
            linkChip.pointerLeftPane()
            return
        }
        model.highlight(number)
        guard PastedImageOptions.isOn(PastedImageOptions.hoverKey) else { return }
        linkChip.hover(
            image.link,
            anchor: LinkChip.Anchor(
                x: frame.midX, lineTop: frame.minY - Self.padding, lineBottom: frame.maxY + Self.padding)
        )
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
    var badge = true
    let space: String
    /// The thumbnail's frame in `space`, nil once the pointer is off it.
    let onHover: (CGRect?) -> Void
    let onOpen: () -> Void

    @State private var frame = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onOpen) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(Style(theme: theme, number: number, isLit: isLit, badge: badge))
        .focusEffectDisabled()
        .pointerStyle(.link)
        .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: isLit)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame = $0 }
        .onHover { onHover($0 ? frame : nil) }
        .contextMenu {
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
        let badge: Bool
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
                    if badge { Text("\(number)")
                        .font(ChromeType.linkChip)
                        .foregroundStyle(isLit ? theme.chrome : Color(colors.title))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isLit ? theme.accent : Color(colors.ground)))
                        .padding(5) }
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// SPIKE: the Pane menu's switches for each treatment.
struct PastedImageMenu: View {
    @AppStorage(PastedImageOptions.trayKey) private var showsTray = true
    @AppStorage(PastedImageOptions.hoverKey) private var showsHover = true
    @AppStorage(PastedImageOptions.chipKey) private var showsChips = true

    @AppStorage(PastedImageOptions.layoutKey) private var layout = PastedImageLayout.footer

    var body: some View {
        Menu("Pasted Images (spike)") {
            Toggle("Thumbnail Tray", isOn: $showsTray)
            Toggle("Hover Preview, Click to Open", isOn: $showsHover)
            Toggle("Label as Chip", isOn: $showsChips)
            Divider()
            Picker("Tray Layout", selection: $layout) {
                ForEach(PastedImageLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }
}
