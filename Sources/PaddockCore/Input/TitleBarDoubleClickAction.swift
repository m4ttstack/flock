/// What a double-click on a window's title bar does, as the user set it in
/// Desktop & Dock. `AppleActionOnDoubleClick` holds the choice;
/// `AppleMiniaturizeOnDoubleClick` is the older boolean, honored only while
/// the newer key is unset.
public enum TitleBarDoubleClickAction: Equatable, Sendable {
    case zoom
    case fill
    case minimize
    case doNothing

    public static let actionKey = "AppleActionOnDoubleClick"
    public static let legacyMinimizeKey = "AppleMiniaturizeOnDoubleClick"

    public init(action: String?, legacyMinimize: Bool) {
        switch action {
        case "Fill": self = .fill
        case "Minimize": self = .minimize
        case "None": self = .doNothing
        case nil: self = legacyMinimize ? .minimize : .zoom
        default: self = .zoom
        }
    }
}
