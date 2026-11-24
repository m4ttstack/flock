import AppKit
import QuickLookUI

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
    /// grows from and shrinks back to; nil fades it instead.
    func show(
        _ shown: [Item], startingAt number: Int, over window: NSWindow?, sourceFrame: @escaping (Int) -> NSRect?
    ) {
        items = shown.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let index = items.firstIndex(where: { $0.number == number }), let panel = QLPreviewPanel.shared() else {
            items = []
            NSSound.beep()
            return
        }
        self.sourceFrame = sourceFrame
        startIndex = index
        if panel.isVisible {
            if panel.dataSource !== self { panel.updateController() }
            panel.reloadData()
            panel.currentPreviewItemIndex = index
            return
        }
        if let window {
            panel.setFrameOrigin(NSPoint(
                x: window.frame.midX - panel.frame.width / 2, y: window.frame.midY - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private var startIndex = 0

    func begin() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(startIndex, max(0, items.count - 1))
    }

    func end() {
        guard let panel = QLPreviewPanel.shared() else { return }
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
