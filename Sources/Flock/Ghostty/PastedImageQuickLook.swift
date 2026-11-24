import AppKit
import FlockCore
import QuickLookUI

/// Pasted images in the Quick Look panel, which AppKit keeps one of. The panel
/// takes its contents from whichever responder accepts control of it: the
/// terminal with the keyboard (`GhosttySurfaceView`), or failing one, the end
/// of the window's chain (`Responder`).
@MainActor
final class PastedImageQuickLook: NSObject {
    static let shared = PastedImageQuickLook()

    final class Item: NSObject, QLPreviewItem {
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

        var previewItemURL: URL? { url }
        var previewItemTitle: String? { title }
    }

    private var items: [Item] = []
    private var sourceFrame: (Int) -> NSRect? = { _ in nil }
    private var isImage: (NSPoint) -> Bool = { _ in false }
    private weak var window: NSWindow?
    private var clickOut: Any?
    private var startIndex = 0
    private var openedAt = Date.distantPast
    private var openingURL: URL?
    private var queued: Task<Void, Never>?
    private static let openingTime: TimeInterval = 0.6

    var hasItems: Bool { !items.isEmpty }

    /// At the end of a window's responder chain, for a click on the tray while
    /// something other than a terminal has the keyboard.
    private final class Responder: NSResponder {
        private nonisolated(unsafe) static var key: UInt8 = 0

        static func install(in window: NSWindow) {
            guard objc_getAssociatedObject(window, &key) == nil else { return }
            let responder = Responder()
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
            objc_setAssociatedObject(window, &key, responder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
            MainActor.assumeIsolated { PastedImageQuickLook.shared.hasItems }
        }

        nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { PastedImageQuickLook.shared.begin() }
        }

        nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { PastedImageQuickLook.shared.end() }
        }
    }

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
        guard remaining <= 0 || QLPreviewPanel.shared()?.isVisible != true else {
            guard shown.first(where: { $0.number == number })?.url != openingURL else { return }
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
        openingURL = items[index].url
        guard let window else { return panel.makeKeyAndOrderFront(nil) }
        Responder.install(in: window)
        let target = QuickLookPlacement.frame(
            image: items[index].size,
            anchor: sourceFrame(number) ?? NSRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0),
            window: window.frame, visibleScreen: (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame,
            chrome: panel.frameRect(forContentRect: .zero).height
        )
        // Before as well as after: opening centers the panel on the screen
        // either way, but without the first it animates to there.
        panel.setFrame(target, display: false)
        panel.makeKeyAndOrderFront(nil)
        if panel.frame != target { panel.setFrame(target, display: true) }
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
