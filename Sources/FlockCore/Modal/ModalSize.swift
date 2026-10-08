import Foundation

/// How much of the area under it a modal's card takes.
public enum ModalSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
