import GhosttyKit

/// AppKit `NSEvent.buttonNumber` to libghostty's button enum, the same table
/// ghostty's own macOS host uses (`Ghostty.Input.MouseButton.init(from
/// NSEventButtonNumber:)`). The enum is numbered the xterm way, where 4-7
/// are wheel directions, so the physical back/forward buttons (AppKit 3 and
/// 4) become EIGHT/NINE and AppKit 7/8 fill the FOUR/FIVE slots; mapping
/// them in order instead would report a back click as a wheel tick.
public enum GhosttyMouseButtons {
    public static func translate(buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_EIGHT
        case 4: GHOSTTY_MOUSE_NINE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_FOUR
        case 8: GHOSTTY_MOUSE_FIVE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }
}
