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

private struct PastedImageDropTarget: View {
    let theme: Theme
    let label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeRadius.surface)
        ZStack {
            shape.fill(theme.accent.opacity(DragVisuals.dropWashOpacity))
            shape.strokeBorder(theme.accent, lineWidth: 2)
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled").font(ChromeType.linkChipSymbol)
                    .foregroundStyle(theme.accent)
                Text(label).font(ChromeType.linkChip).foregroundStyle(theme.textStrong)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.chrome))
            .overlay(Capsule().strokeBorder(theme.rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .padding(4)
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
                .padding(.leading, cell * 0.75)
            Spacer(minLength: 0)
            Text("Image \(label.number)")
                .font(.custom(TerminalFont.face, fixedSize: fontSizePoints * 0.88))
                .foregroundStyle(theme.textStrong)
                .fixedSize()
                .padding(.trailing, cell * 0.8)
        }
        .frame(width: label.rect.width, height: label.rect.height)
        .background {
            // The row's own color over the program's label, then the chip.
            Rectangle().fill(ground)
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.accent.opacity(isLit ? 0.4 : 0.24))
                .padding(.vertical, 1)
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

/// The images in the prompt. It grows leftward until `maxWidth`, then
/// scrolls.
private struct PastedImageTray: View {
    let theme: Theme
    let model: PastedImagesModel
    let linkChip: LinkChipModel
    let space: String
    let numbers: [Int]
    let available: CGSize

    static let inset: CGFloat = 12
    private static let thumbHeight: CGFloat = 128
    private static let thumbWidths: ClosedRange<CGFloat> = 80...228
    private static let gap: CGFloat = 6
    private static let maxWidth: CGFloat = 720

    @State private var position = ScrollPosition(edge: .trailing)
    @State private var offset: CGFloat = 0
    @State private var pointerInside = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.gap) {
                ForEach(numbers, id: \.self) { number in
                    if let image = model.images[number] {
                        PastedImageThumb(
                            theme: theme, number: number, image: image,
                            size: CGSize(width: thumbWidth(number), height: thumbHeight),
                            isLit: model.highlighted == number,
                            space: space,
                            onHover: { frame in hover(number, image, frame) },
                            onOpen: { model.open(number) }
                        )
                        .transition(.opacity)
                    }
                }
            }
            .padding(Self.gap)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        .frame(width: viewport, height: thumbHeight + Self.gap * 2)
        .clipShape(shape)
        .overlay(alignment: .leading) { arrow(forward: false) }
        .overlay(alignment: .trailing) { arrow(forward: true) }
        .background {
            shape.fill(theme.chrome).shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        }
        .overlay { shape.strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth).allowsHitTesting(false) }
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ChromeRadius.container) }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.22) }

    private var thumbHeight: CGFloat {
        max(32, min(Self.thumbHeight, available.height - Self.inset * 2 - Self.gap * 2))
    }

    private func thumbWidth(_ number: Int) -> CGFloat {
        guard let size = model.images[number]?.thumbnail.size, size.height > 0 else { return Self.thumbWidths.lowerBound }
        let scale = thumbHeight / Self.thumbHeight
        let width = thumbHeight * size.width / size.height
        return min(max(width, Self.thumbWidths.lowerBound * scale), Self.thumbWidths.upperBound * scale)
    }

    private var content: CGFloat {
        numbers.reduce(Self.gap) { $0 + thumbWidth($1) + Self.gap }
    }

    private var viewport: CGFloat {
        max(60, min(content, Self.maxWidth, available.width - Self.inset * 2))
    }

    private var overflow: CGFloat { max(0, content - viewport) }

    /// Each thumbnail's span in the scrolled content.
    private var spans: [(number: Int, range: ClosedRange<CGFloat>)] {
        var x = Self.gap
        return numbers.map { number in
            let start = x
            x += thumbWidth(number) + Self.gap
            return (number, start...(x - Self.gap))
        }
    }

    /// How many thumbnails lie wholly past an edge, partly shown ones aside.
    private func hidden(forward: Bool) -> Int {
        spans.filter { forward ? $0.range.lowerBound >= offset + viewport : $0.range.upperBound <= offset }.count
    }

    private func scroll(to x: CGFloat) {
        withAnimation(motion) { position.scrollTo(x: min(max(0, x), overflow)) }
    }

    private func reveal(_ number: Int) {
        guard overflow > 0, let span = spans.first(where: { $0.number == number })?.range else { return }
        let margin: CGFloat = 40
        if span.lowerBound < offset {
            scroll(to: span.lowerBound - margin)
        } else if span.upperBound > offset + viewport {
            scroll(to: span.upperBound + margin - viewport)
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
            anchor: LinkChip.Anchor(x: frame.midX, lineTop: frame.minY - Self.gap, lineBottom: frame.maxY + Self.gap)
        )
    }

    @ViewBuilder
    private func arrow(forward: Bool) -> some View {
        let canMove = forward ? offset < overflow - 1 : offset > 1
        if canMove {
            PastedImageArrow(theme: theme, forward: forward, count: hidden(forward: forward)) {
                scroll(to: offset + (forward ? 1 : -1) * viewport * 0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [theme.chrome, theme.chrome.opacity(0)],
                    startPoint: forward ? .trailing : .leading, endPoint: forward ? .leading : .trailing
                )
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .transition(.opacity)
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
        .buttonStyle(Style(theme: theme, number: number, isLit: isLit))
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: ChromeRadius.control)
            configuration.label
                .overlay { if configuration.isPressed { Color.black.opacity(0.18) } }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(isLit ? theme.accent : theme.rule, lineWidth: isLit ? 2 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(number)")
                        .font(ChromeType.linkChip)
                        .foregroundStyle(isLit ? theme.chrome : theme.textStrong)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isLit ? theme.accent : theme.chrome))
                        .overlay(Capsule().strokeBorder(isLit ? .clear : theme.rule, lineWidth: 1))
                        .padding(5)
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(GridControlFade.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Pages the tray one way, and says how many images are out of sight there.
private struct PastedImageArrow: View {
    let theme: Theme
    let forward: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        GridControlButton(
            theme: theme, shape: AnyShape(Capsule()), restFill: theme.chrome,
            restForeground: theme.textStrong, action: action
        ) {
            HStack(spacing: 3) {
                if forward, count > 0 { Text("\(count)").font(ChromeType.linkChip) }
                Image(systemName: forward ? "chevron.right" : "chevron.left").font(ChromeType.linkChipSymbol)
                if !forward, count > 0 { Text("\(count)").font(ChromeType.linkChip) }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 26)
        }
        .overlay(Capsule().strokeBorder(theme.rule, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .pointerStyle(.link)
        .focusEffectDisabled()
        .accessibilityLabel(forward ? "Next images" : "Previous images")
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
