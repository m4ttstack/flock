import AppKit
import FlockCore

extension NSPasteboard {
    /// What the user's own paste gesture puts into a pane, by
    /// `ClipboardPaste`'s rule: a file URL as its shell-escaped path, anything
    /// else with a string as that string, and image bytes with no file behind
    /// them as the path they get staged at. Nil when the clipboard holds
    /// nothing a terminal can take.
    func pasteText() -> String? {
        let items = pasteboardItems ?? []
        var pieces: [String] = []
        for (item, contribution) in zip(items, ClipboardPaste.plan(for: items.map(Self.described))) {
            switch contribution {
            case .text(let text):
                pieces.append(text)
            case .stageImage(let typeIdentifier, let fileExtension):
                guard
                    let data = item.data(forType: .init(typeIdentifier)),
                    let path = ClipboardImageStaging.stage(data, fileExtension: fileExtension)
                else { continue }
                pieces.append(ClipboardPaste.escape(path))
            case .nothing:
                continue
            }
        }
        return ClipboardPaste.text(joining: pieces)
    }

    /// Whether `pasteText()` would produce anything, deciding it without
    /// staging a thing. Menu validation asks on every menu open, and asking
    /// may not leave a file behind each time.
    var offersPasteText: Bool {
        ClipboardPaste.plan(for: (pasteboardItems ?? []).map(Self.described)).contains { $0 != .nothing }
    }

    private static func described(_ item: NSPasteboardItem) -> PasteboardItemDescription {
        var fileURLPath: String?
        if let plist = item.propertyList(forType: .fileURL),
           let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
           url.isFileURL {
            fileURLPath = url.path
        }
        return PasteboardItemDescription(
            fileURLPath: fileURLPath,
            string: item.string(forType: .string),
            typeIdentifiers: item.types.map(\.rawValue)
        )
    }
}
