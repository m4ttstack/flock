import CoreGraphics
import Foundation

/// Decodes an SVG `path` element's `d` attribute into a `CGPath`, in the
/// coordinates of the document's own viewBox (y down, which is the direction
/// SwiftUI draws in, so a decoded path needs no flip).
///
/// Absolute `M`, `L`, `H`, `V`, `C` and `Z` only -- every command the bundled
/// harness marks use, plus the implicit repeat SVG allows when numbers follow
/// without a new letter. Anything else (a relative command, an arc, a
/// quadratic) returns `nil` rather than a path with pieces silently missing,
/// so a caller falls back to something honest instead of drawing a wrong
/// mark.
public enum VectorMarkPath {
    public static func cgPath(fromSVGPathData data: String) -> CGPath? {
        var reader = Reader(data)
        let path = CGMutablePath()
        var command: Character?
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        while true {
            reader.skipSeparators()
            guard let next = reader.peek() else { break }
            if next.isLetter {
                command = next
                reader.advance()
            } else if command == "M" {
                // Coordinates following a moveto are a polyline, per SVG.
                command = "L"
            } else if command == nil || command == "Z" || command == "z" {
                return nil
            }
            switch command {
            case "M":
                guard let point = reader.point() else { return nil }
                current = point
                subpathStart = point
                path.move(to: point)
            case "L":
                guard !path.isEmpty, let point = reader.point() else { return nil }
                current = point
                path.addLine(to: point)
            case "H":
                guard !path.isEmpty, let x = reader.number() else { return nil }
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard !path.isEmpty, let y = reader.number() else { return nil }
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C":
                guard !path.isEmpty,
                      let first = reader.point(), let second = reader.point(), let end = reader.point()
                else { return nil }
                current = end
                path.addCurve(to: end, control1: first, control2: second)
            case "Z", "z":
                guard !path.isEmpty else { return nil }
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path.copy()
    }

    /// Hand-rolled rather than `Scanner`: SVG path data separates numbers by
    /// comma, whitespace, or nothing at all when the next one carries its own
    /// sign (`10-5` is two numbers), which no general number scanner reads the
    /// same way.
    private struct Reader {
        private let characters: [Character]
        private var index = 0

        init(_ data: String) {
            characters = Array(data)
        }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func advance() {
            index += 1
        }

        mutating func skipSeparators() {
            while let character = peek(), character == "," || character.isWhitespace {
                advance()
            }
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if let character = peek(), character == "+" || character == "-" { advance() }
            var sawDigit = takeDigits()
            if let character = peek(), character == "." {
                advance()
                sawDigit = takeDigits() || sawDigit
            }
            guard sawDigit else {
                index = start
                return nil
            }
            if let character = peek(), character == "e" || character == "E" {
                let beforeExponent = index
                advance()
                if let sign = peek(), sign == "+" || sign == "-" { advance() }
                if !takeDigits() { index = beforeExponent }
            }
            guard let value = Double(String(characters[start..<index])) else { return nil }
            return CGFloat(value)
        }

        private mutating func takeDigits() -> Bool {
            var took = false
            while let character = peek(), character.isASCII, character.isWholeNumber {
                advance()
                took = true
            }
            return took
        }
    }
}
