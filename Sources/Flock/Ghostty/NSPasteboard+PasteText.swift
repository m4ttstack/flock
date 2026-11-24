import AppKit
import FlockCore

extension NSPasteboard {
    /// What the user's own paste gesture puts into a pane, by
    /// `ClipboardPaste`'s rule: a file URL as its shell-escaped path, anything
    /// else with a string as that string, and image bytes with no file behind
    /// them as the path they get staged at. Nil when the clipboard holds
    /// nothing a terminal can take.
    func pasteText() -> String? {
        pasteContents().text
    }

    /// `pasteText`, with the image files the items are or were staged as,
    /// from one reading of the pasteboard. Bytes with no file behind them are
    /// staged for a pane on a machine too: the preview is drawn on this Mac.
    func pasteContents() -> (text: String?, imagePaths: [String]) {
        let built = PasteTextMemo.shared.contents(
            for: .init(name: name.rawValue, changeCount: changeCount),
            build: { self.buildPasteText() }
        )
        return (built.text, built.imagePaths)
    }

    /// Whether `pasteText()` would produce anything, deciding it without
    /// staging a thing. Menu validation asks on every menu open, and asking
    /// may not leave a file behind each time.
    var offersPasteText: Bool {
        ClipboardPaste.plan(for: (pasteboardItems ?? []).map(Self.described)).contains { $0 != .nothing }
    }

    /// The paste for a pane on a herdr machine: files and images are uploaded
    /// and their path there is pasted, since a path on this Mac names nothing
    /// on the machine. Never stages a local copy of its own and never touches
    /// the local paste memo.
    @MainActor
    func remotePasteText(uploader: RemoteFileUploader) async -> RemotePasteOutcome {
        guard let entries = remotePasteEntries() else {
            return .failed(RemotePaste.failureMessage(uploader.label))
        }
        return await RemotePaste.text(of: entries, uploader: uploader)
    }

    /// What `remotePasteText` uploads, read now: the upload outlasts whatever
    /// the pasteboard holds. Nil for an image whose bytes cannot be read.
    func remotePasteEntries() -> [RemotePasteEntry]? {
        let items = pasteboardItems ?? []
        var entries: [RemotePasteEntry] = []
        for (item, contribution) in zip(items, ClipboardPaste.remotePlan(for: items.map(Self.described))) {
            switch contribution {
            case .text(let text):
                entries.append(.text(text))
            case .uploadFile(let localPath):
                entries.append(.file(localPath: localPath))
            case .uploadImage(let typeIdentifier, let fileExtension):
                guard let data = item.data(forType: .init(typeIdentifier)) else { return nil }
                entries.append(.image(data, fileExtension: fileExtension))
            case .nothing:
                continue
            }
        }
        return entries
    }

    private func buildPasteText() -> BuiltPasteText {
        let items = pasteboardItems ?? []
        var pieces: [String] = []
        var stagedPaths: [String] = []
        var imagePaths: [String] = []
        for (item, contribution) in zip(items, ClipboardPaste.plan(for: items.map(Self.described))) {
            switch contribution {
            case .text(let text):
                pieces.append(text)
                if let path = Self.described(item).fileURLPath,
                   ClipboardPaste.becomesImageLabel(path) {
                    imagePaths.append(path)
                }
            case .stageImage(let typeIdentifier, let fileExtension):
                guard
                    let data = item.data(forType: .init(typeIdentifier)),
                    let path = ClipboardImageStaging.stage(data, fileExtension: fileExtension)
                else { continue }
                stagedPaths.append(path)
                if ClipboardPaste.becomesImageLabel(path) { imagePaths.append(path) }
                pieces.append(ClipboardPaste.escape(path))
            case .nothing:
                continue
            }
        }
        return BuiltPasteText(text: ClipboardPaste.text(joining: pieces), stagedPaths: stagedPaths, imagePaths: imagePaths)
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
    var imagePaths: [String]
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
    private var built = BuiltPasteText(stagedPaths: [], imagePaths: [])

    func contents(for key: Key, build: () -> BuiltPasteText) -> BuiltPasteText {
        lock.lock()
        defer { lock.unlock() }
        if key == self.key,
           built.stagedPaths.allSatisfy(FileManager.default.fileExists(atPath:)) {
            return built
        }
        built = build()
        self.key = key
        return built
    }
}

extension RemotePaste {
    @MainActor
    static func text(of entries: [RemotePasteEntry], uploader: RemoteFileUploader) async -> RemotePasteOutcome {
        await resolve(
            entries,
            label: uploader.label,
            token: { String(format: "%08x", UInt32.random(in: .min ... .max)) },
            readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
            upload: { data, fileName in try await uploader.upload(data, named: fileName) }
        )
    }
}
