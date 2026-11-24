import AppKit
import FlockCore
import Observation

/// SPIKE, Flock Dev only: which treatments of a pasted image are drawn.
enum PastedImageOptions {
    static let trayKey = "spike.pastedImage.tray"
    static let hoverKey = "spike.pastedImage.hover"
    static let chipKey = "spike.pastedImage.chip"

    static var isAvailable: Bool { BuildFlavor.isDev }

    static func isOn(_ key: String) -> Bool {
        isAvailable && (UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }
}

struct PastedImage {
    let path: String
    let thumbnail: NSImage

    var link: PaneLink { .file(URL(fileURLWithPath: path)) }

    static func load(_ path: String) -> PastedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return PastedImage(path: path, thumbnail: NSImage(cgImage: image, size: .zero))
    }
}

/// SPIKE: one pane's pasted images, matched to the `[Image #N]` labels the
/// pane's program draws for them.
///
/// The program picks N and says so only on screen, so a paste takes the label
/// that appears after it.
@MainActor
@Observable
final class PastedImagesModel {
    /// What the terminal painted behind a label, as libghostty's frames
    /// carry it (Display P3).
    struct Ground: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    struct Label: Equatable {
        let number: Int
        /// In the pane's top-left space, points.
        let rect: CGRect
        let inPrompt: Bool
        /// Claude Code's own line repeating a sent message's attachment.
        let isAttachmentLine: Bool
        let ground: Ground?
    }

    struct Screen {
        let rows: [String]
        let cell: CGSize
        /// The frame's color at a point, in the pane's top-left space.
        let ground: (CGPoint) -> Ground?
    }

    private(set) var labels: [Label] = []
    private(set) var images: [Int: PastedImage] = [:]
    /// The top of the prompt box's upper rule.
    private(set) var promptTop: CGFloat?
    /// The image the pointer is on, by its label or its thumbnail.
    private(set) var highlighted: Int?

    /// What a drop held over the pane would paste, nil with none.
    var dropLabel: String?

    @ObservationIgnored var trayFrame: CGRect?
    @ObservationIgnored var readScreen: (() -> Screen?)?
    @ObservationIgnored private var pending: [PastedImage] = []
    @ObservationIgnored private var pendingDeadline = Date.distantPast
    @ObservationIgnored private var seen: [Int: Int] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?

    private static let pendingWindow: TimeInterval = 15
    private static let pollInterval: Duration = .milliseconds(150)

    /// Called before the paste is sent, so `seen` is the screen without its label.
    func willPaste(_ paths: [String]) {
        guard PastedImageOptions.isAvailable, !paths.isEmpty else { return }
        let loaded = paths.compactMap(PastedImage.load)
        guard !loaded.isEmpty else { return }
        if pending.isEmpty { seen = Self.counts(scan()) }
        pending += loaded
        pendingDeadline = Date().addingTimeInterval(Self.pendingWindow)
        startPoll()
    }

    /// Only labels flock holds an image for.
    func label(at point: CGPoint) -> Label? {
        labels.first { $0.rect.contains(point) && images[$0.number] != nil }
    }

    func highlight(_ number: Int?) {
        if highlighted != number { highlighted = number }
    }

    func image(for link: PaneLink) -> PastedImage? {
        images.values.first { $0.link == link }
    }

    func open(_ number: Int) {
        guard let image = images[number] else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: image.path))
    }

    private func startPoll() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, self.refresh() else { break }
            }
            self?.poll = nil
        }
    }

    private func refresh() -> Bool {
        let found = scan()
        if !pending.isEmpty {
            let now = Self.counts(found)
            for number in now.keys.sorted() where now[number, default: 0] > seen[number, default: 0] {
                guard !pending.isEmpty else { break }
                images[number] = pending.removeFirst()
            }
            seen = now
            if Date() > pendingDeadline { pending = [] }
        }
        if found != labels { labels = found }
        if let highlighted, !found.contains(where: { $0.number == highlighted }) { highlight(nil) }
        return !images.isEmpty || !pending.isEmpty
    }

    private func scan() -> [Label] {
        guard let screen = readScreen?() else { return [] }
        // Claude Code draws its prompt between two full-width rules.
        let rules = screen.rows.indices.filter { screen.rows[$0].hasPrefix("\u{2500}\u{2500}\u{2500}\u{2500}") }
        let prompt = rules.count >= 2 ? rules[rules.count - 2]..<rules[rules.count - 1] : nil
        let top = prompt.map { CGFloat($0.lowerBound) * screen.cell.height }
        if top != promptTop { promptTop = top }
        var found: [Label] = []
        for (row, line) in screen.rows.enumerated() {
            for match in line.matches(of: /\[Image #(\d+)\]/) {
                guard let number = Int(match.output.1) else { continue }
                let column = line[..<match.range.lowerBound].reduce(0) { $0 + PaneLink.cellWidth(of: $1) }
                let rect = CGRect(
                    x: CGFloat(column) * screen.cell.width, y: CGFloat(row) * screen.cell.height,
                    width: CGFloat(match.output.0.count) * screen.cell.width, height: screen.cell.height
                )
                found.append(Label(
                    number: number,
                    rect: rect,
                    inPrompt: prompt?.contains(row) ?? false,
                    isAttachmentLine: line.drop { $0 == " " }.hasPrefix("\u{23BF}"),
                    // The corner of the `[` cell, which no glyph reaches.
                    ground: screen.ground(CGPoint(x: rect.minX + 0.75, y: rect.minY + 0.75))
                ))
            }
        }
        return found
    }

    private static func counts(_ labels: [Label]) -> [Int: Int] {
        labels.reduce(into: [:]) { $0[$1.number, default: 0] += 1 }
    }
}
