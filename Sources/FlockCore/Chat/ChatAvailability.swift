import Foundation

/// Whether this machine has the chat plugin at all, decided from paths rather
/// than from a failed call. Code past this point knows the binary exists, so a
/// failure there is a real failure worth showing the user.
public enum ChatAvailability {
    public static func resolve(
        environmentOverride: String?, candidates: [(path: String, modified: TimeInterval)]
    ) -> String? {
        if let override = environmentOverride, !override.isEmpty { return override }
        return candidates.max { $0.modified < $1.modified }?.path
    }
}
