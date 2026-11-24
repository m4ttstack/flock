import AppKit
import FlockCore
import QuickLookUI

/// Pasted images in the Quick Look panel, which AppKit keeps one of.
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
    private var isImage: (NSPoint) -> Bool = { _ in false }
    private weak var window: NSWindow?
    private var clickOut: Any?
    private var startIndex = 0
    private var openedAt = Date.distantPast
    private var openingNumber: Int?
    private var queued: Task<Void, Never>?
    private static let openingTime: TimeInterval = 0.6

    var hasItems: Bool { !items.isEmpty }

    /// `sourceFrame` is where an image is drawn on screen, which the panel
    /// grows from and shrinks back to; nil fades it instead. `isImage` is
    /// whether a point in `window` is on something that shows an image.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, sourceFrame: @escaping (Int) -> NSRect?,
        isImage: @escaping (NSPoint) -> Bool
    ) {
        // A reload while the panel is up or still opening runs its opening
        // animation again, so another image waits that out.
        queued?.cancel()
        let remaining = Self.openingTime - Date().timeIntervalSince(openedAt)
        guard remaining <= 0 else {
            guard number != openingNumber else { return }
            queued = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, QLPreviewPanel.shared()?.isVisible == true else { return }
                self?.show(shown, startingAt: number, over: window, sourceFrame: sourceFrame, isImage: isImage)
            }
            return
        }
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
        openingNumber = number
        panel.makeKeyAndOrderFront(nil)
        // After it opens, never before: opening centers it on the screen.
        guard let window else { return }
        let anchor = sourceFrame(number)
            ?? NSRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0)
        panel.setFrame(
            QuickLookPlacement.frame(
                image: items[index].thumbnail.size, anchor: anchor, window: window.frame,
                visibleScreen: (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame,
                chrome: panel.frameRect(forContentRect: .zero).height
            ),
            display: true
        )
    }

    /// The click goes on to what it landed on: the panel is not modal.
    private func closeIfOutside(_ event: NSEvent) {
        guard let window, event.window === window, !isImage(event.locationInWindow),
              let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        panel.orderOut(nil)
    }

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
