import AppKit
import QuickLookUI
import os

private let quickLookLog = Logger(subsystem: "dev.mattstack.flock", category: "quick-look")

/// SPIKE: pasted images in the Quick Look panel, which AppKit keeps one of.
/// The panel takes its contents from whichever responder accepts control of
/// it (`GhosttySurfaceView`), and that hands it this.
@MainActor
final class PastedImageQuickLook: NSObject {
    static let shared = PastedImageQuickLook()

    final class Item: NSObject, QLPreviewItem {
        let number: Int
        let url: URL
        let thumbnail: NSImage

        init(number: Int, url: URL, thumbnail: NSImage) {
            self.number = number
            self.url = url
            self.thumbnail = thumbnail
        }

        var previewItemURL: URL? { url }
        var previewItemTitle: String? { "Image \(number)" }
    }

    private var items: [Item] = []
    private var sourceFrame: (Int) -> NSRect? = { _ in nil }

    var hasItems: Bool { !items.isEmpty }

    /// `sourceFrame` is where an image is drawn on screen, which the panel
    /// grows from and shrinks back to; nil fades it instead. `isImage` is
    /// whether a point in `window` is on something that shows an image.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, sourceFrame: @escaping (Int) -> NSRect?,
        isImage: @escaping (NSPoint) -> Bool
    ) {
        // A reload while the panel is up or still opening runs its opening
        // animation again.
        guard Date().timeIntervalSince(openedAt) > Self.openingTime else { return }
        if let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self,
           (panel.currentPreviewItem as? Item)?.number == number, items.map(\.url) == shown.map(\.url) {
            return
        }
        items = shown.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let index = items.firstIndex(where: { $0.number == number }), let panel = QLPreviewPanel.shared() else {
            items = []
            NSSound.beep()
            return
        }
        self.sourceFrame = sourceFrame
        self.isImage = isImage
        self.window = window
        startIndex = index
        if panel.isVisible {
            if panel.dataSource !== self { panel.updateController() }
            panel.reloadData()
            panel.currentPreviewItemIndex = index
            return
        }
        openedAt = Date()
        let before = panel.frame
        let source = sourceFrame(number)
        let target = window.map { Self.frame(for: items[index], above: source, in: $0, panel: panel) }
        if let target { panel.setFrame(target, display: false) }
        panel.makeKeyAndOrderFront(nil)
        let opened = panel.frame
        if let target, opened != target { panel.setFrame(target, display: true) }
        quickLookLog.notice(
            "open before=\(NSStringFromRect(before), privacy: .public) source=\(source.map(NSStringFromRect) ?? "nil", privacy: .public) target=\(target.map(NSStringFromRect) ?? "nil", privacy: .public) opened=\(NSStringFromRect(opened), privacy: .public) window=\(window.map { NSStringFromRect($0.frame) } ?? "nil", privacy: .public)"
        )
        for delay in [0.1, 0.3, 0.8] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                quickLookLog.notice("after \(delay, privacy: .public)s frame=\(NSStringFromRect(panel.frame), privacy: .public)")
            }
        }
    }

    /// The click goes on to what it landed on: the panel is not modal.
    private func closeIfOutside(_ event: NSEvent) {
        guard let window, event.window === window, !isImage(event.locationInWindow),
              let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        panel.orderOut(nil)
    }

    /// Centered over what was clicked and clear above it, or below it where
    /// there is more room, kept on the window's screen.
    private static func frame(for item: Item, above source: NSRect?, in window: NSWindow, panel: NSPanel) -> NSRect {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 12, dy: 12) ?? window.frame
        let anchor = source ?? NSRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0)
        let gap: CGFloat = 10
        let over = screen.maxY - anchor.maxY - gap, under = anchor.minY - gap - screen.minY
        let room = max(over, under)
        let chrome = panel.frameRect(forContentRect: .zero).height
        let limit = CGSize(width: min(screen.width, window.frame.width * 0.75), height: max(240, room - chrome))
        let image = item.thumbnail.size
        let scale = min(limit.width / max(1, image.width), limit.height / max(1, image.height), 1)
        let size = CGSize(
            width: max(360, image.width * scale), height: max(240, image.height * scale) + chrome)
        let x = min(max(anchor.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = over >= under ? anchor.maxY + gap : anchor.minY - gap - size.height
        return NSRect(
            x: x, y: min(max(y, screen.minY), screen.maxY - size.height), width: size.width, height: size.height
        ).integral
    }

    private var isImage: (NSPoint) -> Bool = { _ in false }
    private weak var window: NSWindow?
    private var clickOut: Any?
    private var startIndex = 0
    private var openedAt = Date.distantPast
    private static let openingTime: TimeInterval = 0.6

    func begin() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(startIndex, max(0, items.count - 1))
        guard clickOut == nil else { return }
        clickOut = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { PastedImageQuickLook.shared.closeIfOutside(event) }
            return event
        }
    }

    func end() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if let clickOut { NSEvent.removeMonitor(clickOut) }
        clickOut = nil
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

extension PastedImageQuickLook: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        (item as? Item).flatMap { sourceFrame($0.number) } ?? .zero
    }

    func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        (item as? Item)?.thumbnail
    }
}
