import Foundation

/// The bytes one paste becomes on its way to the pane's real program.
///
/// A terminal frames a paste in `ESC[200~`/`ESC[201~` so the program can tell
/// pasted input from typed input, which is the only signal that makes a pasted
/// path an attachment rather than a line of text. Flock's own libghostty
/// terminal cannot make that call: its screen is a repaint of herdr's cell grid
/// (herdr's `src/protocol/render_ansi.rs` blits CUP/SGR/DECSCUSR and nothing
/// else), so the pane program's own DECSET 2004 never reaches it and its
/// terminal is never in bracketed-paste mode. The pane's real terminal, on
/// herdr's side, is where that mode lives, and herdr strips a client's frame
/// and re-applies it only when the real terminal has the mode on
/// (`src/server/pane_input.rs`'s `apply_terminal_attach_input`, then
/// `src/pane.rs`'s `paste_payload`), so framing here is right either way.
///
/// herdr takes the bytes as a paste only when they are EXACTLY one complete
/// bracketed paste (`src/raw_input.rs`'s `complete_text_bracketed_paste`);
/// anything else is forwarded as typed input, markers included. The strip pass
/// is what holds that invariant no matter what the user copied.
public enum BracketedPaste {
    public static let startMarker = Data("\u{1B}[200~".utf8)
    public static let endMarker = Data("\u{1B}[201~".utf8)

    /// Every byte xterm replaces with a space on a text insertion, copied from
    /// ghostty's own set (`Vendor/ghostty/src/input/paste.zig`), which applied
    /// it to this same text back when a paste reached the pane through
    /// `ghostty_surface_text`. ESC is in the set, so the frame's own markers
    /// are the only escape sequences a payload can contain.
    private static let stripped: Set<UInt8> = [
        0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F,
        0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F,
    ]

    /// `nil` when there is nothing to paste. Every stripped byte is ASCII, so
    /// replacing bytes never lands inside a multi-byte character.
    public static func payload(_ text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        var body = Data(text.utf8)
        for index in body.indices where stripped.contains(body[index]) {
            body[index] = 0x20
        }
        return startMarker + body + endMarker
    }
}
