import Foundation

/// One pasteboard item as the paste rule sees it: a file URL's path if it
/// carries one, a plain string if it carries one, and the type identifiers it
/// offers. No `NSPasteboardItem` and no AppKit, so the rule is decided over a
/// described clipboard.
public struct PasteboardItemDescription: Equatable, Sendable {
    public var fileURLPath: String?
    public var string: String?
    public var typeIdentifiers: [String]

    public init(
        fileURLPath: String? = nil,
        string: String? = nil,
        typeIdentifiers: [String] = []
    ) {
        self.fileURLPath = fileURLPath
        self.string = string
        self.typeIdentifiers = typeIdentifiers
    }
}

/// What one pasteboard item contributes to a paste.
public enum PasteboardItemPaste: Equatable, Sendable {
    /// Ready to hand to the pane, already escaped if it came from a path.
    case text(String)
    /// Image bytes with no file on disk behind them. A paste can only carry
    /// text, so the caller reads `typeIdentifier` off the item, writes the
    /// bytes to a file named with `fileExtension`, and runs that path through
    /// `ClipboardPaste.escape`.
    case stageImage(typeIdentifier: String, fileExtension: String)
    /// Nothing a terminal can take.
    case nothing
}

/// What the user's own paste gesture produces from the clipboard.
///
/// A screenshot tool's clipboard frequently carries no plain-text flavor at
/// all: `public.file-url` and image data, and nothing for `.string`. Reading
/// only `.string` there pastes nothing, so the file URL is read first and
/// pasted as its shell-escaped absolute path, which is what a terminal program
/// can act on. This is ghostty's rule
/// (`NSPasteboard.getOpinionatedStringContents`), and flock's panes are
/// ghostty surfaces, so the two agree.
///
/// Step three is flock's own: image bytes with no file behind them (a screen
/// capture taken straight to the clipboard) get written to a file so there is
/// a path to paste. herdr's own client does this for the panes it draws, and
/// flock draws those panes instead.
///
/// This decides only what the user's gesture yields. Whether a PROGRAM may
/// read the clipboard at all is `ClipboardReadDisposition`, which denies it.
public enum ClipboardPaste {
    /// Ghostty's escape set, character for character: every one of these gets
    /// a backslash so a path can be pasted into a live shell prompt and
    /// survive as one word.
    private static let escapedCharacters: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    /// Image type identifiers flock will stage, in the order it prefers them.
    /// A screen capture usually offers several at once, and PNG leads because
    /// it is lossless and universally read.
    private static let imageTypes: [(identifier: String, fileExtension: String)] = [
        ("public.png", "png"),
        ("public.jpeg", "jpg"),
        ("public.gif", "gif"),
        ("public.tiff", "tiff"),
        ("com.microsoft.bmp", "bmp"),
        ("org.webmproject.webp", "webp"),
    ]

    public static func decide(_ item: PasteboardItemDescription) -> PasteboardItemPaste {
        if let path = item.fileURLPath, !path.isEmpty {
            return .text(escape(path))
        }
        if let string = item.string {
            return .text(string)
        }
        if let image = imageTypes.first(where: { item.typeIdentifiers.contains($0.identifier) }) {
            return .stageImage(typeIdentifier: image.identifier, fileExtension: image.fileExtension)
        }
        return .nothing
    }

    public static func plan(for items: [PasteboardItemDescription]) -> [PasteboardItemPaste] {
        items.map(decide)
    }

    /// One pass, so a backslash this adds is never escaped a second time.
    public static func escape(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for character in path {
            if escapedCharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// Ghostty joins one paste out of every item with a single space, so a
    /// multi-file clipboard arrives as a shell argument list.
    public static func text(joining pieces: [String]) -> String? {
        pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }
}
