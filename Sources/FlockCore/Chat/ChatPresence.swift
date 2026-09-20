import Foundation

/// The one sign button a pane's popover shows. `.signIn(enabled: false)` is
/// the unknown case: a pane whose status has not arrived yet is not the same
/// as a signed-out pane, so the action it offers must not be clickable.
public enum ChatSignAction: Equatable {
    case signIn(enabled: Bool)
    case signOut
}

public struct ChatPresence {
    public static func signAction(for status: ChatStatus?) -> ChatSignAction {
        guard let status else { return .signIn(enabled: false) }
        return status.signedIn ? .signOut : .signIn(enabled: true)
    }

    public static func canSend(_ status: ChatStatus?) -> Bool {
        guard let status else { return false }
        return status.signedIn
    }
}
