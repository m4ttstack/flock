import GhosttyKit

/// What flock answers when libghostty asks it to confirm a clipboard request,
/// decided PURELY from the kind of request -- no surface, pasteboard or
/// libghostty call inside this type.
///
/// The line is who is asking. An OSC 52 read is a PROGRAM asking for the
/// host's clipboard, on the far side of a herdr pane flock only mirrors, so it
/// is denied. Ghostty's own macOS app asks the user instead, in a sheet; flock
/// has no sheet and will not hand the clipboard over without one.
///
/// This is the backstop for that policy rather than where it is enforced:
/// `GhosttyThemeConfig.configText` sets `clipboard-read = deny`, which makes
/// libghostty refuse a program's read before any callback runs, and a paste is
/// completed empty and re-sent over the pane's control channel
/// (`GhosttyHost`'s read-clipboard callback), so neither kind reaches the
/// confirmation route any more.
///
/// Every kind gets an answer, the unrecognized ones included: a request is a
/// libghostty allocation that only a completion frees.
public enum ClipboardReadDisposition: Equatable, Sendable {
    /// Complete the request with the clipboard contents libghostty offered.
    case allow
    /// Complete the request with an empty clipboard, which is byte for byte
    /// the reply ghostty's own macOS app sends when the user cancels its
    /// confirmation sheet.
    case deny

    public static func decide(_ request: ghostty_clipboard_request_e) -> ClipboardReadDisposition {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: .allow
        default: .deny
        }
    }
}
