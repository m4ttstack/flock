import GhosttyKit

/// What flock answers when libghostty asks it to confirm a clipboard request,
/// decided PURELY from the kind of request -- no surface, pasteboard or
/// libghostty call inside this type.
///
/// The line is who is asking. A paste is the user's own gesture and gets the
/// clipboard, the same answer flock's menu-bar Paste already gives through
/// `ghostty_surface_text`; if the two disagreed, one paste would land and the
/// other would not, by nothing but which key started it. An OSC 52 read is a
/// PROGRAM asking for the host's clipboard, on the far side of a herdr pane
/// flock only mirrors, so it is denied. Ghostty's own macOS app asks the user
/// instead, in a sheet; flock has no sheet and will not hand the clipboard
/// over without one.
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
