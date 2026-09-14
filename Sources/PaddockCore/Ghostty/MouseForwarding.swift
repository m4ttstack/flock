import Foundation

/// Where one mouse event on a pane's ghostty surface should go, decided
/// PURELY from the event, the pane's mode, and whether the pane app has
/// asked for mouse reporting -- no view, `NSEvent`, or libghostty call
/// inside this type, so the whole truth table is testable with plain values.
///
/// The four destinations:
/// - `.toApp` carries a `terminal.mouse` command for the pane's own program,
///   sent over the control FIFO. Herdr encodes it for the pane's real mouse
///   mode; paddock's own libghostty never enters reporting mode, so the app
///   can only ever be reached this way, never through the surface.
/// - `.toHerdrScroll` carries a `terminal.scroll` line for the pane's real,
///   shared herdr viewport -- the wheel's only destination when the app has
///   not claimed the mouse, since libghostty never holds any scrollback of
///   its own to scroll locally (herdr streams viewport repaints, not a
///   scrollback the surface could retain).
/// - `.toSurface` is libghostty handling the event locally (text selection;
///   never scrolling any more -- see `.toHerdrScroll` above).
/// - `.drop` is none of those -- an observe-mode (unfocused) pane has no
///   input path at all.
public enum MouseForwarding {
    /// A pane-domain mouse event, renderer-agnostic. `other(n)` carries
    /// AppKit's own `buttonNumber` for buttons past middle; only left,
    /// middle, and right have a `terminal.mouse` wire representation, so an
    /// `other` button never forwards to the app.
    public enum Button: Equatable, Sendable {
        case left
        case middle
        case right
        case other(Int)
    }

    public enum EventKind: Equatable, Sendable {
        case down
        case up
        case drag
        case moved
        case scrollUp
        case scrollDown
        case scrollLeft
        case scrollRight

        var wireName: String {
            switch self {
            case .down: return "down"
            case .up: return "up"
            case .drag: return "drag"
            case .moved: return "moved"
            case .scrollUp: return "scroll_up"
            case .scrollDown: return "scroll_down"
            case .scrollLeft: return "scroll_left"
            case .scrollRight: return "scroll_right"
            }
        }

        var requiresButton: Bool {
            switch self {
            case .down, .up, .drag: return true
            default: return false
            }
        }

        var isScroll: Bool {
            switch self {
            case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return true
            default: return false
            }
        }

        /// `nil` for `.scrollLeft`/`.scrollRight`: herdr's `terminal.scroll`
        /// only ever moves the viewport vertically (`terminal_sessions.rs`'s
        /// `TerminalControlScrollDirection` has no horizontal case), so
        /// horizontal wheel motion with capture off has nowhere to go and
        /// `decide` drops it.
        var herdrScrollDirection: PaneControlChannel.ScrollDirection? {
            switch self {
            case .scrollUp: return .up
            case .scrollDown: return .down
            default: return nil
            }
        }
    }

    /// A point in the surface's own top-left-origin space, in the SAME units
    /// as `CellSize` (points, after the AppKit y-flip the view already does
    /// for `ghostty_surface_mouse_pos`).
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One terminal cell's size in the same units as `Point`.
    public struct CellSize: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The terminal grid in cells, for clamping a point in the right/bottom
    /// remainder (or past the surface) onto the last cell the way libghostty's
    /// own grid lookup does. herdr drops any event whose cell is outside the
    /// terminal, so without the clamp a down in range whose up drifted into
    /// the remainder would leave the app with an unpaired down.
    public struct GridSize: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// A `terminal.mouse` command for the control FIFO. Cell coordinates are
    /// ZERO-based, matching `ClientMousePosition::Cell`: herdr passes them
    /// straight to its encoder (src/server/pane_input.rs
    /// `terminal_attach_mouse_position`, src/pane/input.rs
    /// `ghostty_mouse_position_for_terminal`), which emits the 1-based SGR
    /// report, so `{"column":9,"row":4}` becomes `ESC[<0;10;5M`.
    public struct Command: Equatable, Sendable {
        public var kind: String
        public var button: String?
        public var column: Int
        public var row: Int
        public var modifiers: UInt8
        public var lines: Int

        public init(kind: String, button: String?, column: Int, row: Int, modifiers: UInt8, lines: Int) {
            self.kind = kind
            self.button = button
            self.column = column
            self.row = row
            self.modifiers = modifiers
            self.lines = lines
        }

        /// The NDJSON object `PaneControlChannel.send` writes. `terminal.`
        /// namespaced (always `terminal.mouse`, never `terminal.scroll` --
        /// that wire shape is `PaneControlChannel.scroll`'s own) so
        /// `ControlBridge.parseForwardableControlCommand` forwards it to
        /// herdr verbatim.
        public func json() -> [String: Any] {
            var object: [String: Any] = [
                "type": "terminal.mouse",
                "kind": kind,
                "column": column,
                "row": row,
                "modifiers": Int(modifiers),
                "lines": lines,
            ]
            if let button { object["button"] = button }
            return object
        }
    }

    public enum Decision: Equatable, Sendable {
        case toApp(Command)
        /// `lines` is always positive -- see `decide`'s own scroll branch.
        case toHerdrScroll(direction: PaneControlChannel.ScrollDirection, lines: Int)
        case toSurface
        case drop
    }

    /// crossterm `KeyModifiers` bits, the exact byte herdr reads back with
    /// `KeyModifiers::from_bits_truncate` on the `AttachMouse` path
    /// (src/server/pane_input.rs:232): SHIFT=1, CONTROL=2, ALT=4, SUPER=8.
    public static func crosstermModifiers(shift: Bool, control: Bool, option: Bool, command: Bool) -> UInt8 {
        var bits: UInt8 = 0
        if shift { bits |= 0b0000_0001 }
        if control { bits |= 0b0000_0010 }
        if option { bits |= 0b0000_0100 }
        if command { bits |= 0b0000_1000 }
        return bits
    }

    /// The one truth table. In order:
    /// 1. observe mode -> `.drop` (no input path; the herdr observe client
    ///    has none either, and the bridge drops stdin in observe mode).
    /// 2. A scroll kind with capture off -> `.toHerdrScroll` when the kind has
    ///    a herdr wire direction (vertical only) and `lines` is positive,
    ///    `.drop` otherwise (horizontal wheel motion, or an accumulator tick
    ///    that crossed no whole cell). Never Shift-gated: wheel has no Shift
    ///    branch, unlike a button event -- see case 3.
    /// 3. A non-scroll kind: Shift held -> `.toSurface` even under capture
    ///    (Shift is the terminal convention for "give me libghostty's
    ///    selection, not the app's mouse"); capture off -> `.toSurface`
    ///    (libghostty handles the click).
    /// 4. otherwise (control + capture on, and for a non-scroll kind no
    ///    Shift): `.toApp`, unless the cell size is not known yet or the
    ///    button has no wire name, in which case it falls back to
    ///    `.toSurface` rather than fabricate a cell.
    public static func decide(
        kind: EventKind,
        button: Button?,
        modifiers: UInt8,
        point: Point,
        cellSize: CellSize?,
        grid: GridSize?,
        captureEnabled: Bool,
        mode: PaneMode,
        shiftHeld: Bool,
        lines: Int
    ) -> Decision {
        if mode == .observe { return .drop }
        if kind.isScroll {
            guard captureEnabled else {
                guard let direction = kind.herdrScrollDirection, lines > 0 else { return .drop }
                return .toHerdrScroll(direction: direction, lines: lines)
            }
        } else {
            if shiftHeld { return .toSurface }
            guard captureEnabled else { return .toSurface }
        }
        guard let command = command(
            kind: kind, button: button, modifiers: modifiers,
            point: point, cellSize: cellSize, grid: grid, lines: lines
        ) else {
            return .toSurface
        }
        return .toApp(command)
    }

    /// Builds the `terminal.mouse` command for an event, or nil when it
    /// cannot be expressed on the wire: no cell size known yet, a button-kind
    /// with no button, or a button past middle (no `ClientMouseButton`
    /// variant). The cell is floored from the point and clamped into `grid`
    /// when one is known (a nil grid leaves the raw floor; herdr is the final
    /// gate). Exposed so the view can build the paired UP that must follow a
    /// DOWN that went `.toApp`, without re-running the whole decision.
    public static func command(
        kind: EventKind,
        button: Button?,
        modifiers: UInt8,
        point: Point,
        cellSize: CellSize?,
        grid: GridSize?,
        lines: Int
    ) -> Command? {
        guard let cellSize, cellSize.width > 0, cellSize.height > 0 else { return nil }
        let wireButton: String?
        switch (kind.requiresButton, button) {
        case (true, .some(let value)):
            guard let name = wireName(for: value) else { return nil }
            wireButton = name
        case (true, .none):
            return nil
        case (false, .some(let value)):
            wireButton = wireName(for: value)
        case (false, .none):
            wireButton = nil
        }
        var column = max(0, Int((point.x / cellSize.width).rounded(.down)))
        var row = max(0, Int((point.y / cellSize.height).rounded(.down)))
        if let grid, grid.columns > 0, grid.rows > 0 {
            column = min(column, grid.columns - 1)
            row = min(row, grid.rows - 1)
        }
        return Command(
            kind: kind.wireName, button: wireButton, column: column, row: row,
            modifiers: modifiers, lines: max(1, lines)
        )
    }

    private static func wireName(for button: Button) -> String? {
        switch button {
        case .left: return "left"
        case .middle: return "middle"
        case .right: return "right"
        case .other: return nil
        }
    }
}
