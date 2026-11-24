import AppKit
import FlockCore
import Observation

struct PastedImage {
    let path: String
    let thumbnail: NSImage

    var url: URL { URL(fileURLWithPath: path) }
    var link: PaneLink { .file(url) }

    /// Sendable because a decoded CGImage is immutable.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    private static let maximumPixels = 1200

    /// Off the main thread: several large captures land in one paste.
    static func load(_ path: String) async -> PastedImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> Decoded? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            ]
            guard
                let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return Decoded(image: image)
        }.value
        return decoded.map { PastedImage(path: path, thumbnail: NSImage(cgImage: $0.image, size: .zero)) }
    }
}

/// One pane's pasted images, matched to the `[Image #N]` labels its program
/// draws for them (`PastedImageMatcher`) and followed as those labels move.
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
        let isAttachmentLine: Bool
        /// Wrapped onto a second row, where a chip has no room.
        let isWrapped: Bool
        let ground: Ground?
    }

    struct Screen {
        /// One string per row, or none where no row holds a label.
        let rows: [String]
        let cell: CGSize
        /// The frame's color at a point, in the pane's top-left space.
        let ground: (CGPoint) -> Ground?
    }

    /// The pane as this model reads it. Every point and rect is in the pane's
    /// top-left space.
    struct Pane {
        /// Nil while the pane is off screen. `whole` asks for the rows even
        /// where none holds a label, for a look at where the prompt is.
        var screen: (_ whole: Bool) -> Screen?
        /// Which frame the pane is showing, nil while it shows none.
        var frame: () -> ObjectIdentifier?
        var window: () -> NSWindow?
        var toScreen: (CGRect) -> NSRect?
        var fromWindow: (NSPoint) -> CGPoint?
    }

    private(set) var labels: [Label] = []
    private(set) var images: [Int: PastedImage] = [:]
    /// The top of the rule over the prompt.
    private(set) var promptTop: CGFloat?
    /// The image the pointer is on, by its label or its thumbnail.
    private(set) var highlighted: Int?
    /// What a drop held over the pane would do, nil with none.
    var dropLabel: String?

    @ObservationIgnored var pane: Pane?
    @ObservationIgnored private(set) var trayFrame: CGRect?
    @ObservationIgnored private var tray: UUID?
    @ObservationIgnored var thumbFrames: [Int: CGRect] = [:]

    @ObservationIgnored private let store: @MainActor () -> PastedImageStore
    @ObservationIgnored private var conversation: String?
    /// Pasted while no conversation was known.
    @ObservationIgnored private var unfiled: [Int: String] = [:]
    /// What a number named before a paste took it, in case the paste turns
    /// out to be another conversation's.
    @ObservationIgnored private var displaced: [Int: String] = [:]
    /// The last conversation known, which an agent that exits leaves.
    @ObservationIgnored private var shownConversation: String?
    /// One that arrived while the pane was off screen.
    @ObservationIgnored private var deferred: String?
    /// Every image this conversation has, whether or not it is loaded: one is
    /// loaded once its label is on screen.
    @ObservationIgnored private var paths: [Int: String] = [:]
    @ObservationIgnored private var loading: Set<Int> = []
    @ObservationIgnored private var touched = Date.distantPast
    @ObservationIgnored private var matcher = PastedImageMatcher()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var scannedFrame: ObjectIdentifier?
    @ObservationIgnored private var frameObserver: CFRunLoopObserver?

    /// Only a backstop: a new frame is what asks for a scan.
    private static let pollInterval: Duration = .milliseconds(500)
    private static let touchInterval: TimeInterval = 24 * 60 * 60

    init(store: @escaping @MainActor () -> PastedImageStore = { .shared }) {
        self.store = store
    }

    var hasConversation: Bool { conversation != nil }

    /// The images in the prompt, in the order their numbers run.
    var promptNumbers: [Int] {
        Set(labels.filter { $0.inPrompt && images[$0.number] != nil }.map(\.number)).sorted()
    }

    /// False while the pane is behind a modal.
    @ObservationIgnored var acceptsDrops = true

    /// `next` is the agent's own session id, nil while herdr reports none. It
    /// arrives after the conversation it names has begun, so images pasted
    /// before it was known, and those on screen, join it.
    func bind(conversation next: String?) {
        guard next != conversation else { return }
        var shown: [Int] = []
        if let next, let previous = shownConversation, previous != next {
            // What is on screen says which images are the new one's.
            guard let screen = pane?.screen(true) else {
                deferred = next
                watch()
                return
            }
            shown = PastedImageLabels(rows: screen.rows).labels.map(\.number)
        }
        deferred = nil
        conversation = next
        guard let next else { return }
        var carried = unfiled
        unfiled = [:]
        if let previous = shownConversation, previous != next {
            // A conversation resumed has its own images, which the screen says
            // nothing about; a fresh one has none.
            let own = store().images(for: next)
            for number in Set(shown) where paths[number] != nil && own[number] == nil {
                carried[number] = paths[number]
                if let path = displaced[number] { _ = store().keep(path, as: number, in: previous) }
            }
            matcher.reset()
            displaced = [:]
        }
        shownConversation = next
        paths = store().images(for: next)
        images = images.filter { (carried[$0.key] ?? paths[$0.key]) == $0.value.path }
        touched = .distantPast
        for (number, path) in carried { assign(path, to: number) }
        watch()
    }

    /// Called before the paste is sent: the labels on screen now are not its.
    /// The answer is for `cancelPaste`, nil where nothing waits.
    func willPaste(_ paths: [String], held: Bool = false) -> Int? {
        guard !paths.isEmpty, let screen = pane?.screen(true) else { return nil }
        let paste = matcher.willPaste(paths, over: PastedImageLabels(rows: screen.rows), held: held, now: Date())
        watch()
        return paste
    }

    func pasteWasSent(_ paste: Int?) {
        if let paste { matcher.sent(paste, now: Date()) }
    }

    func cancelPaste(_ paste: Int?) {
        if let paste { matcher.cancel(paste) }
    }

    func trayMoved(_ tray: UUID, to frame: CGRect) {
        self.tray = tray
        trayFrame = frame
    }

    /// A tray that has replaced this one has the frame now.
    func trayWent(_ tray: UUID) {
        guard self.tray == tray else { return }
        trayFrame = nil
    }

    /// Only labels flock holds an image for.
    func label(at point: CGPoint) -> Label? {
        labels.first { $0.rect.contains(point) && images[$0.number] != nil }
    }

    func highlight(_ number: Int?) {
        if highlighted != number { highlighted = number }
    }

    func holds(_ link: PaneLink) -> Bool {
        images.values.contains { $0.link == link }
    }

    /// One file can be pasted more than once, so the one under the pointer
    /// answers first.
    func number(for link: PaneLink) -> Int? {
        if let highlighted, images[highlighted]?.link == link { return highlighted }
        return images.filter { $0.value.link == link }.keys.max()
    }

    func open(_ number: Int) {
        guard let image = images[number] else { return }
        NSWorkspace.shared.open(image.url)
    }

    /// What was clicked.
    enum QuickLookOrigin {
        case tray
        case text(CGRect)
    }

    /// Opens on `number`, with the arrow keys reaching the images beside it:
    /// the prompt's for one of those, else every sent one on screen.
    func quickLook(_ number: Int, from origin: QuickLookOrigin) {
        let inPrompt = labels.contains { $0.number == number && $0.inPrompt }
        let numbers = Set(labels.filter { $0.inPrompt == inPrompt }.map(\.number)).union([number])
        let items = numbers.sorted().compactMap { number in
            images[number].map { PastedImageQuickLook.Item(number: number, url: $0.url, thumbnail: $0.thumbnail) }
        }
        PastedImageQuickLook.shared.show(items, startingAt: number, over: pane?.window()) { [weak self] shown in
            guard let self else { return nil }
            let rect: CGRect? = switch origin {
            case .tray: visibleThumbFrame(shown)
            case .text(let clicked):
                shown == number ? clicked : labels.first { $0.number == shown && $0.inPrompt == inPrompt }?.rect
            }
            return rect.flatMap { self.pane?.toScreen($0) }
        } isImage: { [weak self] point in
            guard let self, let point = pane?.fromWindow(point) else { return false }
            return label(at: point) != nil || trayFrame?.contains(point) == true
        }
    }

    private func visibleThumbFrame(_ number: Int) -> CGRect? {
        guard let tray = trayFrame, let thumb = thumbFrames[number],
              tray.contains(CGPoint(x: thumb.midX, y: thumb.midY))
        else { return nil }
        return thumb
    }

    // MARK: - Following the screen

    private func watch() {
        guard poll == nil else { return }
        watchFrames()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                refresh()
                if paths.isEmpty, !matcher.isWaiting, deferred == nil { break }
            }
            self?.poll = nil
            self?.stopWatchingFrames()
        }
    }

    /// libghostty hands its layer each frame on the main thread, so the end
    /// of a main run loop pass is the first moment a new one can be seen, and
    /// is ahead of the commit that shows it.
    private func watchFrames() {
        guard frameObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] observer, _ in
            guard let self else {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                return
            }
            MainActor.assumeIsolated { self.scanNewFrame() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        frameObserver = observer
    }

    private func stopWatchingFrames() {
        if let frameObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), frameObserver, .commonModes) }
        frameObserver = nil
    }

    private func scanNewFrame() {
        let frame = pane?.frame()
        guard frame != scannedFrame else { return }
        scannedFrame = frame
        if frame != nil { refresh() }
    }

    func refresh() {
        // A pane off screen has no labels to show, and its pastes keep waiting.
        guard let screen = pane?.screen(matcher.isWaiting) else {
            show([], promptTop: nil)
            return
        }
        if let deferred { bind(conversation: deferred) }
        let read = PastedImageLabels(rows: screen.rows)
        for match in matcher.match(read, now: Date()) {
            assign(match.path, to: match.number)
        }
        for number in Set(read.labels.map(\.number)) { load(number) }
        touchIfInUse(read)
        show(
            read.labels.map { label in
                let rect = CGRect(
                    x: CGFloat(label.column) * screen.cell.width, y: CGFloat(label.row) * screen.cell.height,
                    width: CGFloat(label.cells) * screen.cell.width, height: screen.cell.height
                )
                return Label(
                    number: label.number, rect: rect, inPrompt: label.inPrompt,
                    isAttachmentLine: label.isAttachmentLine, isWrapped: label.tail != nil,
                    // The corner of the `[` cell, which no glyph reaches.
                    ground: screen.ground(CGPoint(x: rect.minX + 0.75, y: rect.minY + 0.75))
                )
            },
            promptTop: read.promptRow.map { CGFloat($0) * screen.cell.height }
        )
    }

    /// Retention counts from the last time an image was on screen, and once a
    /// day is close enough for it.
    private func touchIfInUse(_ read: PastedImageLabels) {
        guard let conversation, Date().timeIntervalSince(touched) > Self.touchInterval,
              read.labels.contains(where: { paths[$0.number] != nil })
        else { return }
        touched = Date()
        store().touch(conversation)
    }

    private func show(_ found: [Label], promptTop top: CGFloat?) {
        if found != labels { labels = found }
        if top != promptTop { promptTop = top }
        if let highlighted, !found.contains(where: { $0.number == highlighted }) { highlight(nil) }
    }

    private func assign(_ path: String, to number: Int) {
        if let held = paths[number], held != path, displaced[number] == nil { displaced[number] = held }
        if let conversation {
            paths[number] = store().keep(path, as: number, in: conversation)
        } else {
            paths[number] = path
            unfiled[number] = path
        }
        load(number)
    }

    private func load(_ number: Int) {
        guard let path = paths[number], images[number]?.path != path, loading.insert(number).inserted else { return }
        Task {
            let image = await PastedImage.load(path)
            loading.remove(number)
            // Another paste or conversation took the number meanwhile.
            guard paths[number] == path else { return load(number) }
            images[number] = image
            if image == nil { paths[number] = nil }
        }
    }
}
