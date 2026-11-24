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

        init(number: Int, title: String, url: URL, thumbnail: NSImage, size: CGSize? = nil) {
            self.number = number
            self.title = title
            self.url = url
            self.thumbnail = thumbnail
            self.size = size ?? thumbnail.size
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
        panel.setFrame(target, display: false)
        if wasOpen, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let source = sourceFrame(number), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let opened = generation
        animate(from: source, to: target, fadingIn: true) { [weak self] in
            guard let self, generation == opened else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let from = panel.frame
        let back = items.indices.contains(index) ? sourceFrame(items[index].number) : nil
        unwatch()
        panel.orderOut(nil)
        preview?.previewItem = nil
        window?.makeKey()
        guard let back, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            endZoom()
            return
        }
        animate(from: from, to: back, fadingIn: false) {}
    }

    private func step(_ by: Int) {
        guard items.indices.contains(index + by) else { return }
        index += by
        fill()
        panel.setFrame(target, display: true)
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
        image.image = item.thumbnail
        preview?.previewItem = item.url as NSURL
        if let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) {
            openButton.title = "Open in \(FileManager.default.displayName(atPath: app.path))"
            openButton.isHidden = false
        } else {
            openButton.isHidden = true
        }
        openButton.sizeToFit()
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

        // Under the preview, which draws nothing until it has loaded.
        image.imageScaling = .scaleProportionallyDown
        let content = NSView(frame: panel.contentLayoutRect)
        image.frame = content.bounds
        image.autoresizingMask = [.width, .height]
        content.addSubview(image)
        if let preview = QLPreviewView(frame: content.bounds, style: .normal) {
            // Otherwise it can never show another item.
            preview.shouldCloseWithWindow = false
            preview.autoresizingMask = [.width, .height]
            content.addSubview(preview)
            self.preview = preview
        }
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
    private func animate(from: NSRect, to: NSRect, fadingIn: Bool, then done: @escaping @MainActor () -> Void) {
        endZoom()
        let zoom = NSWindow(contentRect: from, styleMask: .borderless, backing: .buffered, defer: false)
        zoom.isReleasedWhenClosed = false
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
        zoom.alphaValue = fadingIn ? M.zoomAlpha : 1
        zoom.setFrame(from, display: true)
        zoom.orderFront(nil)
        self.zoom = zoom
        NSAnimationContext.runAnimationGroup { context in
            context.duration = M.zoomDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            zoom.animator().setFrame(to, display: true)
            zoom.animator().alphaValue = fadingIn ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                done()
                guard let self, self.zoom === zoom else { return }
                self.endZoom()
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
