import AppKit
import FlockCore
import QuickLookUI
import UniformTypeIdentifiers

/// Pasted images and dropped files at full size, in a panel of flock's own.
///
/// Not AppKit's `QLPreviewPanel`: that centers itself on the screen each time
/// it opens, and can only be moved once it has been seen there. This one is
/// put where it belongs before it is first shown.
@MainActor
final class PastedImageQuickLook: NSObject {
    static let shared = PastedImageQuickLook()

    struct Item {
        let number: Int
        let title: String
        let url: URL
        let thumbnail: NSImage
        /// Of what is previewed.
        let size: CGSize
        /// Shown as a picture, rather than through Quick Look's own view.
        let isImage: Bool

        init(number: Int, title: String, url: URL, thumbnail: NSImage, size: CGSize? = nil) {
            self.number = number
            self.title = title
            self.url = url
            self.thumbnail = thumbnail
            self.size = size ?? thumbnail.size
            isImage = size == nil
        }
    }

    private typealias M = ChromeMetrics.PastedImages

    private var items: [Item] = []
    private var index = 0
    private var anchor = NSRect.zero
    private var sourceFrame: (Int) -> NSRect? = { _ in nil }
    private var isImage: (NSPoint) -> Bool = { _ in false }
    private var hasFocus: () -> Bool = { false }
    private weak var window: NSWindow?
    private var clickOut: Any?
    private var windowClosing: Any?
    private var windowTookKeyboard: Any?
    private var clickingImage = false
    private var heldKey: Any?
    /// Counts opens, steps and closes, so an animation that has been overtaken ends
    /// nothing.
    private var generation = 0
    private(set) var zoom: NSWindow?

    private(set) lazy var panel = makePanel()
    let image = NSImageView()
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let openHolder = NSView()
    private let content = Content()
    private var preview: QLPreviewView?
    private var loading: Task<Void, Never>?
    private var playing: Playing?
    /// What `image` was decoded to.
    private var loadedPixels = 0
    /// The frame it was last given, which it leaves only by being moved or resized.
    private var placed = NSRect.zero
    private var isMoved = false
    private var isResized = false

    private(set) var isOpen = false

    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `sourceFrame` is where an image is drawn on screen, which the panel
    /// grows from and shrinks back to, if it is drawn. `isImage` is
    /// whether a point in `window` is on something that shows an image, and
    /// `hasFocus` whether the pane showing it is the one with focus there.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, isDark: Bool,
        sourceFrame: @escaping (Int) -> NSRect?, isImage: @escaping (NSPoint) -> Bool,
        hasFocus: @escaping () -> Bool = { false }
    ) {
        let present = shown.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let window, let start = present.firstIndex(where: { $0.number == number }) else {
            NSSound.beep()
            return
        }
        let same = isOpen && self.window === window && items.indices.contains(index)
            && items[index].url == present[start].url && items[index].number == number
        let wasOpenHere = isOpen && self.window === window && panel.isVisible
        let grows = !wasOpenHere && !reduceMotion()
        items = present
        index = start
        self.sourceFrame = sourceFrame
        self.isImage = isImage
        self.hasFocus = hasFocus
        if same {
            retitle()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        self.window = window
        let source = sourceFrame(number)
        anchor = source ?? NSRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0)
        isOpen = true
        generation += 1
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        watch(window)
        fill()
        // In place, drawn and key before it is seen: what grows is a picture
        // of it, title bar and all, and it takes over where that ends.
        if grows, source != nil { panel.alphaValue = 0 }
        place(keepingPlace: wasOpenHere)
        attach(panel, to: window)
        panel.makeKeyAndOrderFront(nil)
        // Not the Open button, which would take Space.
        panel.makeFirstResponder(nil)
        guard grows, let source else { return land() }
        let opened = generation
        animate(from: Self.fit(panel.frame.size, over: source), to: panel.frame) { [weak self] in
            guard let self, generation == opened else { return }
            land()
        }
    }

    /// The panel itself is seen, whatever was growing into it.
    private func land() {
        panel.alphaValue = 1
        endZoom()
        loadPreview()
        play()
    }

    func close() { close(animated: true) }

    private func close(animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let back = items.indices.contains(index) ? sourceFrame(items[index].number) : nil
        unwatch()
        stopPlaying()
        // Drawn out of process, so a picture of it can come out blank.
        unloadPreview()
        let closed = generation
        if animated, let back, !reduceMotion() {
            animate(from: zoom?.frame ?? panel.frame, to: Self.fit(panel.frame.size, over: back)) { [weak self] in
                guard let self, generation == closed else { return }
                endZoom()
            }
        } else {
            endZoom()
        }
        detach(panel)
        panel.orderOut(nil)
        release()
        if animated { window?.makeKey() }
    }

    /// The panel lasts as long as the app, and a picture at full size is large.
    private func release() {
        loading?.cancel()
        image.image = nil
        items = []
        sourceFrame = { _ in nil }
        isImage = { _ in false }
        hasFocus = { false }
    }

    /// Above the window whatever comes forward in it, and with it across
    /// Spaces and into full screen.
    private func attach(_ child: NSWindow, to window: NSWindow) {
        guard child.parent !== window else { return }
        detach(child)
        window.addChildWindow(child, ordered: .above)
    }

    private func detach(_ child: NSWindow) {
        child.parent?.removeChildWindow(child)
    }

    func step(_ by: Int) {
        guard items.indices.contains(index + by) else { return }
        index += by
        generation += 1
        fill()
        place(keepingPlace: true)
        land()
    }

    @objc private func openInApp() {
        guard items.indices.contains(index) else { return }
        NSWorkspace.shared.open(items[index].url)
    }

    // MARK: - Contents

    private var target: NSRect {
        guard items.indices.contains(index) else { return panel.frame }
        let window = window?.frame ?? .zero
        return QuickLookPlacement.frame(
            image: items[index].size, anchor: anchor, window: window,
            visibleScreen: (self.window?.screen ?? NSScreen.main)?.visibleFrame ?? window,
            chrome: panel.frameRect(forContentRect: .zero).height
        )
    }

    private func place(keepingPlace: Bool) {
        let next = target
        content.natural = items[index].thumbnail.size
        content.placed = panel.contentRect(forFrameRect: next).size
        isResized = keepingPlace && (isResized || panel.frame.size != placed.size)
        isMoved = keepingPlace && (isMoved || panel.frame.origin != placed.origin)
        let frame: NSRect
        if isResized {
            frame = panel.frame
        } else if isMoved {
            frame = QuickLookPlacement.frame(
                size: next.size, centeredOn: panel.frame,
                visibleScreen: (panel.screen ?? NSScreen.main)?.visibleFrame ?? next)
        } else {
            frame = next
        }
        panel.setFrame(frame, display: true)
        content.fit()
        placed = panel.frame
        if items[index].isImage { loadFullImage(items[index]) }
    }

    private func fill() {
        let item = items[index]
        retitle()
        unloadPreview()
        stopPlaying()
        loadedPixels = 0
        image.image = item.thumbnail
        if let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) {
            openButton.title = "Open in \(FileManager.default.displayName(atPath: app.path))"
            openButton.isHidden = false
        } else {
            openButton.isHidden = true
        }
        openButton.sizeToFit()
        // A title bar gives an accessory the width it already has.
        let height = panel.frameRect(forContentRect: .zero).height
        openHolder.setFrameSize(NSSize(width: openButton.frame.width + M.previewTitlebarInset, height: height))
        openButton.setFrameOrigin(NSPoint(x: 0, y: ((height - openButton.frame.height) / 2).rounded()))
    }

    private func retitle() {
        let title = items[index].title
        panel.title = items.count == 1 ? title : "\(title) (\(index + 1) of \(items.count))"
    }

    /// The thumbnail is capped, and reads soft in a large panel.
    private func loadFullImage(_ item: Item) {
        let url = item.url
        let points = max(item.thumbnail.size.width, item.thumbnail.size.height, image.frame.width, image.frame.height)
        let pixels = Int((points * (window?.backingScaleFactor ?? 2)).rounded(.up))
        guard pixels > loadedPixels else { return }
        loadedPixels = pixels
        loading?.cancel()
        loading = Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) { () -> Decoded? in
                Self.decode(url, pixels: pixels).map { Decoded(image: $0) }
            }.value
            guard let self, let full, !Task.isCancelled, playing == nil, items.indices.contains(index), items[index].url == url else { return }
            // The thumbnail's size in points, so nothing moves.
            image.image = NSImage(cgImage: full.image, size: item.thumbnail.size)
        }
    }

    /// No larger than it is drawn, so that drawing it does no decoding of its
    /// own, and the right way up.
    nonisolated static func decode(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Sendable because a decoded CGImage is immutable.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    /// An animated image, over the still one.
    private func play() {
        guard isOpen, playing == nil, items.indices.contains(index), items[index].isImage, !reduceMotion() else { return }
        let item = items[index]
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), CGImageSourceGetCount(source) > 1,
              let type = CGImageSourceGetType(source) as String?, Self.animatedTypes.contains(type)
        else { return }
        let playing = Playing()
        self.playing = playing
        CGAnimateImageAtURLWithBlock(item.url as CFURL, nil) { [weak self] _, frame, stop in
            MainActor.assumeIsolated {
                guard let self, self.playing === playing else {
                    stop.pointee = true
                    return
                }
                self.image.image = NSImage(cgImage: frame, size: item.thumbnail.size)
            }
        }
    }

    private func stopPlaying() {
        playing = nil
    }

    private final class Playing {}

    /// Others hold several pictures without being animations.
    private static let animatedTypes: Set<String> = [UTType.gif.identifier, UTType.png.identifier]

    /// Last, since loading one holds up the main thread.
    private func loadPreview() {
        guard isOpen, items.indices.contains(index), !items[index].isImage, let content = panel.contentView,
              let preview = QLPreviewView(frame: content.bounds, style: .normal)
        else { return }
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = items[index].url as NSURL
        content.addSubview(preview)
        panel.makeFirstResponder(preview)
        image.isHidden = true
        self.preview = preview
    }

    private func unloadPreview() {
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        image.isHidden = false
    }

    /// The panel's shape, shrunk to sit on `source`.
    private static func fit(_ size: CGSize, over source: NSRect) -> NSRect {
        let scale = min(source.width / max(1, size.width), source.height / max(1, size.height))
        let fitted = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return NSRect(
            x: source.midX - fitted.width / 2, y: source.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
    }

    /// The panel as drawn, title bar included.
    func picture() -> NSImage? {
        panel.layoutIfNeeded()
        guard let frame = panel.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let image = NSImage(size: frame.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func makePanel() -> Panel {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onClose = { [weak self] key in
            self?.close()
            self?.swallow(key)
        }
        panel.onStep = { [weak self] by in
            guard let self, items.count > 1 else { return false }
            step(by)
            return true
        }

        image.imageScaling = .scaleProportionallyUpOrDown
        content.frame = panel.contentLayoutRect
        content.image = image
        content.addSubview(image)
        panel.contentView = content

        openButton.bezelStyle = .accessoryBarAction
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openInApp)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        openHolder.addSubview(openButton)
        accessory.view = openHolder
        panel.addTitlebarAccessoryViewController(accessory)
        return panel
    }

    // MARK: - Growing and shrinking

    /// A window of its own: a titled one cannot be as small as a label.
    private func animate(from: NSRect, to: NSRect, then done: @escaping @MainActor () -> Void) {
        endZoom()
        let zoom = NSWindow(contentRect: from, styleMask: .borderless, backing: .buffered, defer: false)
        zoom.isReleasedWhenClosed = false
        // Its own would fade it away as the panel takes over.
        zoom.animationBehavior = .none
        zoom.isOpaque = false
        zoom.backgroundColor = .clear
        zoom.ignoresMouseEvents = true
        zoom.hasShadow = true
        zoom.level = panel.level
        let view = NSImageView(frame: NSRect(origin: .zero, size: from.size))
        view.image = picture()
        view.imageScaling = .scaleAxesIndependently
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = M.zoomCornerRadius
        view.layer?.masksToBounds = true
        zoom.contentView = view
        zoom.setFrame(from, display: true)
        if let window { attach(zoom, to: window) }
        zoom.orderFront(nil)
        self.zoom = zoom
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.zoomDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            zoom.animator().setFrame(to, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.zoom === zoom else { return }
                done()
            }
        }
    }

    private func endZoom() {
        if let zoom { detach(zoom) }
        zoom?.orderOut(nil)
        zoom = nil
    }

    // MARK: - Closing

    /// A click elsewhere in the window closes the panel and goes on to what
    /// it landed on: the panel is not modal.
    private func watch(_ window: NSWindow) {
        unwatch()
        clickOut = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                guard self.isImage(event.locationInWindow) else { return self.close() }
                self.clickingImage = true
                DispatchQueue.main.async { self.clickingImage = false }
                guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return }
                // The click makes its own window key, and the keyboard is
                // the panel's while it is open.
                DispatchQueue.main.async {
                    if self.isOpen, self.window === event.window { self.panel.makeKey() }
                }
            }
            return event
        }
        windowClosing = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        }
        // A pane takes the keyboard as it gets focus, and Escape would be its.
        // The panel's own, focused by the click that opened it, gives it back.
        windowTookKeyboard = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.clickingImage else { return }
                // The pane is made first responder after its window is key.
                DispatchQueue.main.async {
                    guard self.isOpen, !self.panel.isKeyWindow else { return }
                    if self.hasFocus() { self.panel.makeKey() } else { self.close() }
                }
            }
        }
    }

    private func unwatch() {
        if let clickOut { NSEvent.removeMonitor(clickOut) }
        if let windowClosing { NotificationCenter.default.removeObserver(windowClosing) }
        if let windowTookKeyboard { NotificationCenter.default.removeObserver(windowTookKeyboard) }
        clickOut = nil
        windowClosing = nil
        windowTookKeyboard = nil
    }

    /// The rest of the press that closed the panel, held down or let go,
    /// which would otherwise go to the pane.
    private func swallow(_ key: UInt16) {
        endSwallow()
        heldKey = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let (rest, ends) = HeldKey.read(
                key, isDown: event.type == .keyDown, isRepeat: event.type == .keyDown && event.isARepeat,
                of: event.keyCode)
            if ends { MainActor.assumeIsolated { self?.endSwallow() } }
            return rest ? nil : event
        }
    }

    private func endSwallow() {
        if let heldKey { NSEvent.removeMonitor(heldKey) }
        heldKey = nil
    }

    /// The image at its own size in the panel it was placed in, and larger
    /// as the panel is.
    final class Content: NSView {
        var image: NSView?
        var natural = CGSize.zero
        var placed = CGSize.zero

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            fit()
        }

        func fit() {
            image?.frame = QuickLookPlacement.image(natural, in: bounds.size, placedIn: placed)
        }
    }

    final class Panel: NSPanel {
        var onClose: (UInt16) -> Void = { _ in }
        /// Whether there was anything to step through.
        var onStep: (Int) -> Bool = { _ in false }

        override var canBecomeKey: Bool { true }

        /// Before the preview, which has the keyboard and takes some of these
        /// for itself.
        override func sendEvent(_ event: NSEvent) {
            guard event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
                return super.sendEvent(event)
            }
            switch event.keyCode {
            case 49 where firstResponder is NSButton: super.sendEvent(event)
            case 53, 49: if !event.isARepeat { onClose(event.keyCode) }
            case 123, 126: if !onStep(-1) { super.sendEvent(event) }
            case 124, 125: if !onStep(1) { super.sendEvent(event) }
            default: super.sendEvent(event)
            }
        }
    }
}

extension PastedImageQuickLook: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    /// Sharp at the size it has been given.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard isOpen, items.indices.contains(index), items[index].isImage, playing == nil else { return }
        loadFullImage(items[index])
    }
}
