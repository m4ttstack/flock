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
    private var zoom: NSWindow?

    private lazy var panel = makePanel()
    private let image = NSImageView()
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private var preview: QLPreviewView?

    private(set) var isOpen = false

    /// `sourceFrame` is where an image is drawn on screen, which the panel
    /// grows from and shrinks back to; nil fades it instead. `isImage` is
    /// whether a point in `window` is on something that shows an image.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, sourceFrame: @escaping (Int) -> NSRect?,
        isImage: @escaping (NSPoint) -> Bool
    ) {
        let present = shown.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let window, let start = present.firstIndex(where: { $0.number == number }) else {
            NSSound.beep()
            return
        }
        if isOpen, items.indices.contains(index), items[index].url == present[start].url,
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
        watch(window)
        fill()
        panel.setFrame(target, display: true)
        if wasOpen, panel.isVisible {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            loadPreview()
            return
        }
        guard let source = sourceFrame(number), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            loadPreview()
            return
        }
        let opened = generation
        // In place and drawn before the picture reaches it, so there is never
        // a moment with neither.
        panel.alphaValue = 0
        panel.orderFront(nil)
        animate(from: source, to: pictureFrame) { [weak self] in
            guard let self, generation == opened else { return }
            // Over the picture that just landed, which it draws in the same
            // place: only the chrome is seen to fade in.
            panel.makeKeyAndOrderFront(nil)
            fadePanel(to: 1) { [weak self] in
                guard let self, generation == opened else { return }
                endZoom()
                loadPreview()
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let from = pictureFrame
        let back = items.indices.contains(index) ? sourceFrame(items[index].number) : nil
        unwatch()
        unloadPreview()
        window?.makeKey()
        guard let back, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            endZoom()
            return
        }
        let closed = generation
        animate(from: from, to: back) { [weak self] in
            guard let self, generation == closed else { return }
            endZoom()
        }
        fadePanel(to: 0) { [weak self] in
            guard let self, generation == closed else { return }
            panel.orderOut(nil)
        }
    }

    private func step(_ by: Int) {
        guard items.indices.contains(index + by) else { return }
        index += by
        fill()
        panel.setFrame(target, display: true)
        loadPreview()
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
    }

    /// The thumbnail is capped, and reads soft in a large panel.
    private func loadFullImage(_ item: Item) {
        let url = item.url
        Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) { () -> Decoded? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { return nil }
                return Decoded(image: image)
            }.value
            guard let self, let full, items.indices.contains(index), items[index].url == url else { return }
            // The thumbnail's size in points, so nothing moves.
            image.image = NSImage(cgImage: full.image, size: item.thumbnail.size)
        }
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

    /// Where the picture is drawn, on screen.
    private var pictureFrame: NSRect {
        let content = panel.contentRect(forFrameRect: panel.frame)
        guard items.indices.contains(index) else { return content }
        let size = items[index].thumbnail.size
        let scale = min(1, content.width / max(1, size.width), content.height / max(1, size.height))
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: content.midX - drawn.width / 2, y: content.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height)
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
        let holder = NSStackView(views: [openButton])
        holder.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: M.previewTitlebarInset)
        accessory.view = holder
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
        view.image = items.indices.contains(index) ? items[index].thumbnail : nil
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
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

    private func fadePanel(to alpha: CGFloat, then done: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? M.chromeFadeIn : M.chromeFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done() }
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

    private final class Panel: NSPanel {
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
