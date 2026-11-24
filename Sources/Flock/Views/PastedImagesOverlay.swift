import FlockCore
import SwiftUI

/// SPIKE: a pane's pasted images, drawn over its terminal as chips in place
/// of their labels, a tray over the prompt, and a preview under the pointer.
struct PastedImagesOverlay: View {
    let theme: Theme
    let model: PastedImagesModel
    let space: String

    @AppStorage(PastedImageOptions.trayKey) private var showsTray = true
    @AppStorage(PastedImageOptions.hoverKey) private var showsHover = true
    @AppStorage(PastedImageOptions.chipKey) private var showsChips = true

    private static let thumbHeight: CGFloat = 128
    private static let thumbWidths: ClosedRange<CGFloat> = 80...228
    private static let gap: CGFloat = 6
    private static let previewLimit = CGSize(width: 420, height: 280)

    var body: some View {
        GeometryReader { pane in
            ZStack(alignment: .topLeading) {
                Color.clear
                if showsChips {
                    ForEach(Array(model.labels.enumerated()), id: \.offset) { _, label in
                        if !label.isAttachmentLine, let image = model.images[label.number] {
                            chip(label, image).offset(x: label.rect.minX, y: label.rect.minY)
                        }
                    }
                    .allowsHitTesting(false)
                }
                if showsTray, let top = model.promptTop, !trayNumbers.isEmpty {
                    let scale = trayScale(in: pane.size, top: top)
                    tray(scale)
                        .offset(
                            x: max(Self.gap, pane.size.width - trayWidth(scale) - Self.gap * 2),
                            y: max(Self.gap, top - Self.thumbHeight * scale - Self.gap * 3)
                        )
                }
                if showsHover, let label = model.hovered, let image = model.images[label.number] {
                    preview(label, image, in: pane.size).allowsHitTesting(false)
                }
            }
        }
    }

    private func chip(_ label: PastedImagesModel.Label, _ image: PastedImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return HStack(spacing: 4) {
            Image(nsImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: label.rect.height - 4, height: label.rect.height - 6)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text("Image \(label.number)")
                .font(.system(size: label.rect.height * 0.6, weight: .medium))
                .foregroundStyle(theme.textStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 3)
        .frame(width: label.rect.width, height: label.rect.height)
        .background {
            // Opaque: the program's own label is under here.
            shape.fill(theme.terminalGround)
            shape.fill(theme.accent.opacity(0.22))
            shape.strokeBorder(theme.accent.opacity(0.6), lineWidth: 1)
        }
    }

    private var trayNumbers: [Int] {
        Set(model.labels.filter { $0.inPrompt && model.images[$0.number] != nil }.map(\.number)).sorted()
    }

    private func thumbWidth(_ number: Int) -> CGFloat {
        guard let size = model.images[number]?.thumbnail.size, size.height > 0 else { return Self.thumbWidths.lowerBound }
        let width = Self.thumbHeight * size.width / size.height
        return min(max(width, Self.thumbWidths.lowerBound), Self.thumbWidths.upperBound)
    }

    private func trayWidth(_ scale: CGFloat) -> CGFloat {
        trayNumbers.reduce(Self.gap) { $0 + thumbWidth($1) * scale + Self.gap }
    }

    /// Full size until the thumbnails outgrow the pane.
    private func trayScale(in pane: CGSize, top: CGFloat) -> CGFloat {
        let gaps = CGFloat(trayNumbers.count + 1) * Self.gap
        let images = trayWidth(1) - gaps
        let width = (pane.width - gaps - Self.gap * 4) / max(1, images)
        let height = (top - Self.gap * 4) / Self.thumbHeight
        return max(0.2, min(1, width, height))
    }

    private func tray(_ scale: CGFloat) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(trayNumbers, id: \.self) { number in
                if let image = model.images[number] {
                    Button { model.open(number) } label: {
                        Image(nsImage: image.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbWidth(number) * scale, height: Self.thumbHeight * scale)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.rule, lineWidth: 1))
                            .overlay(alignment: .bottomTrailing) {
                                Text("\(number)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.textStrong)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.chrome))
                                    .padding(3)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open image \(number)")
                }
            }
        }
        .padding(Self.gap)
        .background(card)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { model.trayFrame = $0 }
        .onDisappear { model.trayFrame = nil }
    }

    private func preview(
        _ label: PastedImagesModel.Label, _ image: PastedImage, in pane: CGSize
    ) -> some View {
        let source = image.thumbnail.size
        let limit = CGSize(
            width: max(40, min(Self.previewLimit.width, pane.width - 32)),
            height: max(40, min(Self.previewLimit.height, max(label.rect.minY, pane.height - label.rect.maxY) - 32))
        )
        let scale = min(1, limit.width / max(1, source.width), limit.height / max(1, source.height))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let outer = CGSize(width: size.width + Self.gap * 2, height: size.height + Self.gap * 2)
        let fitsAbove = label.rect.minY - outer.height - Self.gap >= 0
        return Image(nsImage: image.thumbnail)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(Self.gap)
            .background(card)
            .offset(
                x: max(Self.gap, min(label.rect.minX, pane.width - outer.width - Self.gap)),
                y: fitsAbove ? label.rect.minY - outer.height - Self.gap : label.rect.maxY + Self.gap
            )
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.chrome)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
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
