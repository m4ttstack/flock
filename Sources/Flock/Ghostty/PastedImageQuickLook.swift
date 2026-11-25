import AppKit
import FlockCore
import QuickLookUI

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
    private weak var window: NSWindow?
    private var clickOut: Any?
    private var windowClosing: Any?
    /// Counts opens and closes, so an animation that has been overtaken ends
    /// nothing.
    private var generation = 0
    private(set) var zoom: NSWindow?

    private(set) lazy var panel = makePanel()
    private let image = NSImageView()
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let openHolder = NSView()
    private var preview: QLPreviewView?

    private(set) var isOpen = false

    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `sourceFrame` is where an image is drawn on screen, which the panel
    /// grows from and shrinks back to; nil fades it instead. `isImage` is
    /// whether a point in `window` is on something that shows an image.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, isDark: Bool,
        sourceFrame: @escaping (Int) -> NSRect?, isImage: @escaping (NSPoint) -> Bool
    ) {
        let present = shown.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let window, let start = present.firstIndex(where: { $0.number == number }) else {
            NSSound.beep()
            return
        }
        if isOpen, self.window === window, items.indices.contains(index), items[index].url == present[start].url,
           items[index].number == number {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let wasOpen = isOpen && self.window === window
        items = present
        index = start
        self.sourceFrame = sourceFrame
        self.isImage = isImage
        self.window = window
        anchor = sourceFrame(number) ?? NSRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0)
        isOpen = true
        generation += 1
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        watch(window)
        fill()
        panel.setFrame(target, display: true)
        guard !(wasOpen && panel.isVisible), let source = sourceFrame(number),
              !reduceMotion()
        else {
            panel.makeKeyAndOrderFront(nil)
            land()
            return
        }
        let opened = generation
        // In place, drawn and key before it is seen: what grows is a picture
        // of it, title bar and all, and it takes over where that ends.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
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
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let back = items.indices.contains(index) ? sourceFrame(items[index].number) : nil
        unwatch()
        // Drawn out of process, so a picture of it can come out blank.
        unloadPreview()
        guard let back, !reduceMotion() else {
            panel.orderOut(nil)
            endZoom()
            window?.makeKey()
            return
        }
        let closed = generation
        animate(from: zoom?.frame ?? panel.frame, to: Self.fit(panel.frame.size, over: back)) { [weak self] in
            guard let self, generation == closed else { return }
            endZoom()
        }
        panel.orderOut(nil)
        window?.makeKey()
    }

    func step(_ by: Int) {
        guard items.indices.contains(index + by) else { return }
        index += by
        generation += 1
        fill()
        panel.setFrame(target, display: true)
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

    private func fill() {
        let item = items[index]
        panel.title = items.count == 1 ? item.title : "\(item.title) (\(index + 1) of \(items.count))"
        unloadPreview()
        image.image = item.thumbnail
        if item.isImage { loadFullImage(item) }
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

    /// The thumbnail is capped, and reads soft in a large panel.
    private func loadFullImage(_ item: Item) {
        let url = item.url
        Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) { () -> Decoded? in
                Self.fullImage(at: url).map { Decoded(image: $0) }
            }.value
            guard let self, let full, items.indices.contains(index), items[index].url == url else { return }
            // The thumbnail's size in points, so nothing moves.
            image.image = NSImage(cgImage: full.image, size: item.thumbnail.size)
        }
    }

    /// The right way up, as the thumbnail is: a plain decode leaves out the
    /// turn a camera records beside the pixels.
    nonisolated static func fullImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let turn = properties[kCGImagePropertyOrientation] as? Int, turn != 1,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Sendable because a decoded CGImage is immutable.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    /// Last, since loading one holds up the main thread.
    private func loadPreview() {
        guard isOpen, items.indices.contains(index), !items[index].isImage, let content = panel.contentView,
              let preview = QLPreviewView(frame: content.bounds, style: .normal)
        else { return }
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = items[index].url as NSURL
        content.addSubview(preview)
        self.preview = preview
    }

    private func unloadPreview() {
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
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
        panel.onClose = { [weak self] in self?.close() }
        panel.onStep = { [weak self] in self?.step($0) }

        image.imageScaling = .scaleProportionallyDown
        let content = NSView(frame: panel.contentLayoutRect)
        image.frame = content.bounds
        image.autoresizingMask = [.width, .height]
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
                guard let self, event.window === self.window, !self.isImage(event.locationInWindow) else { return }
                self.close()
            }
            return event
        }
        windowClosing = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func unwatch() {
        if let clickOut { NSEvent.removeMonitor(clickOut) }
        if let windowClosing { NotificationCenter.default.removeObserver(windowClosing) }
        clickOut = nil
        windowClosing = nil
    }

    final class Panel: NSPanel {
        var onClose: () -> Void = {}
        var onStep: (Int) -> Void = { _ in }

        override var canBecomeKey: Bool { true }

        /// Before the preview, which has the keyboard and takes some of these
        /// for itself.
        override func sendEvent(_ event: NSEvent) {
            guard event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
                return super.sendEvent(event)
            }
            switch event.keyCode {
            case 53, 49: onClose()
            case 123, 126: onStep(-1)
            case 124, 125: onStep(1)
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
}
