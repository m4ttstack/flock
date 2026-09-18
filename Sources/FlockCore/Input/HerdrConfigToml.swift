import Foundation

/// The one slice of a herdr `config.toml` flock reads: the `[keys]` table and
/// the `[[keys.command]]` tables under it. Every other section is skipped,
/// values included, so nothing outside the keymap can make this fail.
struct HerdrKeysSection: Equatable, Sendable {
    /// One entry per `[keys]` key, the scalar form carried as a one-element
    /// list so a `BindingConfig` written either way reads the same.
    var values: [String: [String]] = [:]
    /// Each `[[keys.command]]` table in the order it appeared, string-valued
    /// fields only.
    var commands: [[String: String]] = []
}

/// A reader for the TOML shapes a `[keys]` section is written in: string and
/// string-list values, comments, and array-of-tables headers. It is not a
/// TOML parser, and it only has to survive the rest of the file rather than
/// understand it.
enum HerdrConfigToml {
    static func keysSection(in text: String) -> HerdrKeysSection {
        var section = HerdrKeysSection()
        var path: [String] = []
        var command: [String: String]?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = code(in: lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty { continue }

            if let header = header(in: line) {
                if let finished = command {
                    section.commands.append(finished)
                    command = nil
                }
                path = header.path
                if header.isArrayElement, header.path == ["keys", "command"] {
                    command = [:]
                }
                continue
            }

            guard let separator = assignment(in: line) else { continue }
            let key = unquoted(String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
            var raw = String(line[line.index(after: separator)...])
            // Consumed for every section, not just the one being read: a
            // value that opens a bracket and does not close it on its own
            // line leaves continuation lines behind, and one of those
            // starting with `[` would otherwise read as a section header.
            while depth(of: raw) > 0, index < lines.count {
                raw += "\n" + code(in: lines[index])
                index += 1
            }
            guard path == ["keys"] || command != nil else { continue }

            switch value(of: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .string(let string):
                if command != nil {
                    command?[key] = string
                } else {
                    section.values[key] = [string]
                }
            case .list(let strings):
                guard command == nil else { continue }
                section.values[key] = strings
            case .unreadable:
                continue
            }
        }

        if let command {
            section.commands.append(command)
        }
        return section
    }

    private enum Value {
        case string(String)
        case list([String])
        case unreadable
    }

    private static func header(in line: String) -> (path: [String], isArrayElement: Bool)? {
        if line.hasPrefix("[["), line.hasSuffix("]]") {
            return (path(of: String(line.dropFirst(2).dropLast(2))), true)
        }
        if line.hasPrefix("["), line.hasSuffix("]") {
            return (path(of: String(line.dropFirst().dropLast())), false)
        }
        return nil
    }

    private static func path(of header: String) -> [String] {
        header.split(separator: ".").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    private static func assignment(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    /// How many brackets the text leaves open, counting only those outside a
    /// string.
    private static func depth(of text: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            }
        }
        return max(depth, 0)
    }

    private static func value(of raw: String) -> Value {
        if let string = string(of: raw) {
            return .string(string)
        }
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return .unreadable }
        // An empty list stays a list: `zoom = []` is how a binding is turned
        // off, and reading it as unreadable would restore herdr's default.
        return .list(
            elements(of: String(raw.dropFirst().dropLast())).compactMap {
                string(of: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
    }

    private static func elements(of body: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                current.append(character)
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "[", "{":
                depth += 1
                current.append(character)
            case "]", "}":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                elements.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elements.append(current)
        }
        return elements
    }

    private static func string(of raw: String) -> String? {
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return nil }
        var unescaped = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": unescaped.append("\n")
                case "t": unescaped.append("\t")
                case "r": unescaped.append("\r")
                default: unescaped.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                unescaped.append(character)
            }
        }
        return unescaped
    }

    /// Everything on `line` before an unquoted `#`.
    private static func code(in line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[line.startIndex..<index])
            }
        }
        return line
    }
}
