import Foundation

/// The one-line confirmation shown after a selection lands on the clipboard:
/// a quoted preview for a single line, a line count otherwise.
public enum CopiedToastMessage {
    static let previewLimit = 24

    public static func make(for text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var trimmed = lines[...]
        while let last = trimmed.last, last.isEmpty { trimmed = trimmed.dropLast() }
        while let first = trimmed.first, first.isEmpty { trimmed = trimmed.dropFirst() }

        switch trimmed.count {
        case 0:
            return "Copied"
        case 1:
            var preview = trimmed[trimmed.startIndex]
            if preview.count > previewLimit {
                preview = String(preview.prefix(previewLimit)) + "\u{2026}"
            }
            return "Copied \u{201C}\(preview)\u{201D}"
        default:
            return "Copied \(trimmed.count) lines"
        }
    }
}
