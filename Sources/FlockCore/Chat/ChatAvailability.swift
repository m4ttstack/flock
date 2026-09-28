import Foundation

/// Whether this machine has the chat plugin at all, decided from paths rather
/// than from a failed call. Code past this point knows the binary exists, so a
/// failure there is a real failure worth showing the user.
public enum ChatAvailability {
    /// `candidates` in priority order; nil and empty entries are sources that
    /// do not apply to this build.
    public static func resolve(_ candidates: [String?], isRunnable: (String) -> Bool) -> String? {
        candidates.lazy.compactMap { $0 }.first { !$0.isEmpty && isRunnable($0) }
    }
}
