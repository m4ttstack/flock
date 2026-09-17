import Foundation

/// Picks the terminal face flock renders panes in.
///
/// Parity first: the panes flock mirrors are the same panes the user sees
/// in their own terminal, so the face follows that terminal's `font-family`
/// when it names one and CoreText can actually resolve it. A family CoreText
/// cannot resolve silently falls back to Helvetica rather than failing, which
/// is why every candidate is round-tripped through the availability check
/// before it is used.
public enum TerminalFontResolution {
    /// The face used when no configured family resolves. Public, present at
    /// `/System/Library/Fonts/Menlo.ttc`, and the family ghostty's own font
    /// discovery round-trips.
    public static let fallbackFace = "Menlo"

    /// The `font-family` value of a ghostty-style config, or nil when the
    /// text has no usable one. Later assignments win, matching ghostty's own
    /// last-one-wins config semantics; a commented line is not an assignment.
    public static func configuredFamily(inConfigText text: String) -> String? {
        var found: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("font-family") else { continue }
            let afterKey = line.dropFirst("font-family".count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            let value = afterKey.dropFirst().trimmingCharacters(in: .whitespaces)
            let unquoted = value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2
                ? String(value.dropFirst().dropLast())
                : value
            guard !unquoted.isEmpty else { continue }
            found = unquoted
        }
        return found
    }

    /// `configuredFamily` filtered through `isAvailable`, else the fallback.
    public static func face(
        configText: String?, isAvailable: (String) -> Bool
    ) -> String {
        guard let configText, let family = configuredFamily(inConfigText: configText),
              isAvailable(family) else { return fallbackFace }
        return family
    }
}
