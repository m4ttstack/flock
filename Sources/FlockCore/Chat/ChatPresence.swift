import Foundation

public enum ButtonState: Equatable {
    case primary
    case secondary
}

public struct ChatPresence {
    public static func buttons(for status: ChatStatus) -> (signIn: ButtonState, signOut: ButtonState) {
        if status.signedIn {
            return (signIn: .secondary, signOut: .primary)
        } else {
            return (signIn: .primary, signOut: .secondary)
        }
    }

    public static func canSend(_ status: ChatStatus?) -> Bool {
        guard let status else { return false }
        return status.signedIn
    }
}
