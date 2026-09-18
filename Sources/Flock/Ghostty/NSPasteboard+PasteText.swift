import AppKit
import FlockCore

extension NSPasteboard {
    /// What the user's own paste gesture puts into a pane, by
    /// `ClipboardPaste`'s rule: a file URL as its shell-escaped path, anything
    /// else with a string as that string, and image bytes with no file behind
    /// them as the path they get staged at. Nil when the clipboard holds
    /// nothing a terminal can take.
    func pasteText() -> String? {
        PasteTextMemo.shared.text(
            for: .init(name: name.rawValue, changeCount: changeCount),
            build: { self.buildPasteText() }
        )
    }

    /// Whether `pasteText()` would produce anything, deciding it without
    /// staging a thing. Menu validation asks on every menu open, and asking
    /// may not leave a file behind each time.
    var offersPasteText: Bool {
        ClipboardPaste.plan(for: (pasteboardItems ?? []).map(Self.described)).contains { $0 != .nothing }
    }

    private func buildPasteText() -> BuiltPasteText {
        let items = pasteboardItems ?? []
        var pieces: [String] = []
        var stagedPaths: [String] = []
        for (item, contribution) in zip(items, ClipboardPaste.plan(for: items.map(Self.described))) {
            switch contribution {
            case .text(let text):
                pieces.append(text)
            case .stageImage(let typeIdentifier, let fileExtension):
                guard
                    let data = item.data(forType: .init(typeIdentifier)),
                    let path = ClipboardImageStaging.stage(data, fileExtension: fileExtension)
                else { continue }
                stagedPaths.append(path)
                pieces.append(ClipboardPaste.escape(path))
            case .nothing:
                continue
            }
        }
        return BuiltPasteText(text: ClipboardPaste.text(joining: pieces), stagedPaths: stagedPaths)
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

private struct BuiltPasteText {
    var text: String?
    var stagedPaths: [String]
}

/// One staged file per clipboard, not one per read.
///
/// libghostty answers a PROGRAM's OSC 52 read through the same clipboard read
/// as the user's own paste, and answers it before `ClipboardReadDisposition`
/// gets to deny it. Without this, a program asking in a loop would write a
/// copy of the user's screenshot on every ask.
///
/// `@unchecked Sendable`: every field is read and written only inside `lock`,
/// which matters because the reads arrive on both the main thread and
/// libghostty's own.
private final class PasteTextMemo: @unchecked Sendable {
    /// A change count counts changes to one pasteboard, so the pasteboard is
    /// half the identity of a clipboard's contents.
    struct Key: Equatable {
        let name: String
        let changeCount: Int
    }

    static let shared = PasteTextMemo()

    private let lock = NSLock()
    private var key: Key?
    private var text: String?
    private var stagedPaths: [String] = []

    func text(for key: Key, build: () -> BuiltPasteText) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if key == self.key,
           stagedPaths.allSatisfy(FileManager.default.fileExists(atPath:)) {
            return text
        }
        let built = build()
        self.key = key
        text = built.text
        stagedPaths = built.stagedPaths
        return built.text
    }
}
