import Foundation

enum ButtonState: Equatable {
    case primary
    case secondary
}

struct ChatPresence {
    static func buttons(for status: ChatStatus) -> (signIn: ButtonState, signOut: ButtonState) {
        if status.signedIn {
            return (signIn: .secondary, signOut: .primary)
        } else {
            return (signIn: .primary, signOut: .secondary)
        }
    }

    static func canSend(_ status: ChatStatus?) -> Bool {
        guard let status else { return false }
        return status.signedIn
    }
}
