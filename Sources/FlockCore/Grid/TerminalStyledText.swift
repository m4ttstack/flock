import Foundation

/// A colour as a terminal program names it: a slot of the 256-colour palette,
/// or a direct RGB value. Slots 0...15 are the theme's; the rest are fixed.
public enum TerminalColor: Hashable, Sendable {
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// The SGR attributes a cell carries that the card can draw. A nil colour is
/// the terminal's default for that slot.
public struct TerminalStyle: Hashable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false
    public var invisible = false

    public static let plain = TerminalStyle()

    public init(
        foreground: TerminalColor? = nil, background: TerminalColor? = nil, bold: Bool = false, dim: Bool = false,
        italic: Bool = false, underline: Bool = false, inverse: Bool = false, strikethrough: Bool = false,
        invisible: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strikethrough = strikethrough
        self.invisible = invisible
    }

    /// Whether a blank cell in this style still paints something.
    var paintsBlanks: Bool { background != nil || inverse }
}

public struct StyledRun: Hashable, Sendable {
    public var text: String
    public var style: TerminalStyle

    public init(text: String, style: TerminalStyle) {
        self.text = text
        self.style = style
    }
}

/// One screen row as styled runs. Trailing blanks that paint nothing are
/// already gone; blanks under a background stay, since they are a bar.
public struct StyledRow: Hashable, Sendable {
    public let runs: [StyledRun]

    public init(runs: [StyledRun]) {
        self.runs = Self.trimmingUnpaintedTail(runs.filter { !$0.text.isEmpty })
    }

    public init(plain text: String) {
        self.init(runs: [StyledRun(text: text, style: .plain)])
    }

    /// The row as the text format reads it: no styling and no trailing
    /// blanks, painted or not.
    public var text: String {
        let joined = runs.map(\.text).joined()
        var end = joined.endIndex
        while end > joined.startIndex {
            let previous = joined.index(before: end)
            guard Self.isBlank(joined[previous]) else { break }
            end = previous
        }
        return String(joined[..<end])
    }

    /// Terminal cells the row spans: an East Asian wide character takes two.
    public var columns: Int { Self.columns(of: runs.map(\.text)) }

    public static func columns(of texts: [String]) -> Int {
        texts.reduce(0) { total, text in
            total + text.reduce(0) { $0 + cellWidth(of: $1) }
        }
    }

    static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r"
    }

    private static func trimmingUnpaintedTail(_ runs: [StyledRun]) -> [StyledRun] {
        var runs = runs
        while let last = runs.last, !last.style.paintsBlanks {
            let kept = String(last.text.reversed().drop(while: isBlank).reversed())
            if kept.isEmpty {
                runs.removeLast()
                continue
            }
            runs[runs.count - 1].text = kept
            break
        }
        return runs
    }

    private static func cellWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else { return 1 }
        switch scalar {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

/// Reads terminal output carrying ANSI escapes (herdr's `ansi` read format)
/// into styled rows.
///
/// Only SGR changes what is drawn. Every other escape (cursor moves, mode
/// sets, OSC strings, DCS and the like) is consumed whole, so none of its
/// bytes reach the text. Style carries across rows, as it does in the
/// terminal: a row break does not reset it.
public enum TerminalStyledText {
    public static func rows(of ansi: String) -> [StyledRow] {
        var parser = Parser()
        for scalar in ansi.unicodeScalars {
            parser.consume(scalar)
        }
        return parser.finish()
    }

    private struct Parser {
        enum State {
            case ground
            case escape
            /// ESC followed by intermediates (`ESC ( B`): ends on the final byte.
            case escapeIntermediate
            case csi
            /// OSC, DCS, SOS, PM, APC: a string that ends on BEL or ST.
            case string
            case stringEscape
        }

        var state = State.ground
        var style = TerminalStyle.plain
        var params = ""
        var rows: [StyledRow] = []
        var runs: [StyledRun] = []
        var text = String.UnicodeScalarView()
        var runStyle = TerminalStyle.plain

        mutating func consume(_ scalar: Unicode.Scalar) {
            switch state {
            case .ground:
                ground(scalar)
            case .escape:
                escape(scalar)
            case .escapeIntermediate:
                if (0x30...0x7E).contains(scalar.value) { state = .ground }
            case .csi:
                csi(scalar)
            case .string:
                if scalar.value == 0x07 || scalar.value == 0x9C {
                    state = .ground
                } else if scalar.value == 0x1B {
                    state = .stringEscape
                }
            case .stringEscape:
                // ESC \ is ST; any other ESC inside a string also ends it.
                state = .ground
                if scalar != "\\" { escape(scalar) }
            }
        }

        mutating func finish() -> [StyledRow] {
            endRow()
            return rows
        }

        private mutating func ground(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x1B:
                state = .escape
            case 0x9B:
                params = ""
                state = .csi
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                state = .string
            case 0x0A:
                endRow()
            case 0x09:
                tab()
            case 0x00...0x1F, 0x7F...0x9F:
                break
            default:
                append(scalar)
            }
        }

        private mutating func escape(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "[":
                params = ""
                state = .csi
            case "]", "P", "X", "^", "_":
                state = .string
            default:
                state = (0x20...0x2F).contains(scalar.value) ? .escapeIntermediate : .ground
            }
        }

        private mutating func csi(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x20...0x3F:
                params.unicodeScalars.append(scalar)
            case 0x40...0x7E:
                state = .ground
                if scalar == "m" { applySGR(params) }
            case 0x1B:
                state = .escape
            default:
                state = .ground
            }
        }

        private mutating func append(_ scalar: Unicode.Scalar) {
            if style != runStyle {
                flushRun()
                runStyle = style
            }
            text.append(scalar)
        }

        /// A tab moves to the next 8-column stop without painting the cells it
        /// passes, so they are spaces in the plain style.
        private mutating func tab() {
            let column = StyledRow.columns(of: runs.map(\.text) + [String(text)])
            let held = style
            style = .plain
            for _ in 0..<(Self.tabStop - column % Self.tabStop) {
                append(" ")
            }
            style = held
        }

        private static let tabStop = 8

        private mutating func flushRun() {
            guard !text.isEmpty else { return }
            runs.append(StyledRun(text: String(text), style: runStyle))
            text = String.UnicodeScalarView()
        }

        private mutating func endRow() {
            flushRun()
            rows.append(StyledRow(runs: runs))
            runs = []
        }

        /// A private-marker CSI ending in `m` (`ESC [ > 4 ; 2 m`) is not SGR.
        private mutating func applySGR(_ params: String) {
            if let first = params.unicodeScalars.first, (0x3C...0x3F).contains(first.value) { return }
            let fields = params.split(separator: ";", omittingEmptySubsequences: false).map { field in
                field.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            }
            var index = 0
            while index < fields.count {
                let field = fields[index]
                let code = field.first.flatMap { $0 } ?? 0
                index += 1
                switch code {
                case 0: style = .plain
                case 1: style.bold = true
                case 2: style.dim = true
                case 3: style.italic = true
                case 4: style.underline = field.count < 2 || (field[1] ?? 1) != 0
                case 7: style.inverse = true
                case 8: style.invisible = true
                case 9: style.strikethrough = true
                case 21: style.underline = true
                case 22:
                    style.bold = false
                    style.dim = false
                case 23: style.italic = false
                case 24: style.underline = false
                case 27: style.inverse = false
                case 28: style.invisible = false
                case 29: style.strikethrough = false
                case 30...37: style.foreground = .indexed(UInt8(code - 30))
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(UInt8(code - 40))
                case 49: style.background = nil
                case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
                case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
                case 38, 48, 58:
                    let color = Self.extendedColor(field: field, fields: fields, index: &index)
                    if code == 38, let color { style.foreground = color }
                    if code == 48, let color { style.background = color }
                default:
                    break
                }
            }
        }

        /// `38;5;n` and `38;2;r;g;b` take the fields after their own; the
        /// colon forms (`38:5:n`, `38:2::r:g:b`, `38:2:r:g:b`) carry
        /// everything in the one field.
        private static func extendedColor(field: [Int?], fields: [[Int?]], index: inout Int) -> TerminalColor? {
            var values: [Int?]
            if field.count > 1 {
                values = Array(field.dropFirst())
            } else {
                guard index < fields.count else { return nil }
                let mode = fields[index].first.flatMap { $0 }
                let count = mode == 5 ? 2 : mode == 2 ? 4 : 1
                values = fields[index..<min(fields.count, index + count)].map { $0.first.flatMap { $0 } }
                index += values.count
            }
            guard let mode = values.first.flatMap({ $0 }) else { return nil }
            values.removeFirst()
            switch mode {
            case 5:
                guard let slot = values.first.flatMap({ $0 }), (0...255).contains(slot) else { return nil }
                return .indexed(UInt8(slot))
            case 2:
                // The colon form may carry a colour-space id ahead of r:g:b.
                let channels = values.count >= 4 ? Array(values.suffix(3)) : values
                guard channels.count == 3 else { return nil }
                let bytes = channels.map { UInt8(clamping: $0 ?? 0) }
                return .rgb(red: bytes[0], green: bytes[1], blue: bytes[2])
            default:
                return nil
            }
        }
    }
}

/// Where each palette slot's colour comes from.
public enum TerminalPalette {
    /// Slots 0...15 from `ansi`, the theme's terminal palette; 16...231 the
    /// xterm 6x6x6 cube; 232...255 its grey ramp.
    public static func rgb(of color: TerminalColor, ansi: [GhosttyThemeColor]) -> GhosttyThemeColor {
        switch color {
        case let .rgb(red, green, blue):
            return GhosttyThemeColor(red: red, green: green, blue: blue)
        case let .indexed(slot) where slot < 16:
            return ansi.indices.contains(Int(slot)) ? ansi[Int(slot)] : GhosttyThemeColor(red: 0, green: 0, blue: 0)
        case let .indexed(slot) where slot < 232:
            let cube = Int(slot) - 16
            func level(_ step: Int) -> UInt8 { step == 0 ? 0 : UInt8(55 + step * 40) }
            return GhosttyThemeColor(red: level(cube / 36), green: level(cube / 6 % 6), blue: level(cube % 6))
        case let .indexed(slot):
            let grey = UInt8(8 + (Int(slot) - 232) * 10)
            return GhosttyThemeColor(red: grey, green: grey, blue: grey)
        }
    }
}
