import XCTest

/// Which edge of a drop target a pane drag aims at. Named for the canvas
/// directions the drop resolver distinguishes rather than for writing
/// direction.
enum Edge {
    case left
    case right
    case top
    case bottom
}

@MainActor
extension XCUIApplication {
    /// Launches Paddock against a scratch session. The socket is the point:
    /// without `HERDR_SOCKET_PATH` the app resolves the default session, which
    /// is whatever real work is running on this machine, and its pane bridges
    /// would take those panes over.
    ///
    /// `PADDOCK_HERDR_BIN` and `PADDOCK_RESNAPSHOT_SECONDS` are carried across
    /// from the runner's own environment when `Scripts/e2e.sh` set them, so a
    /// case opts into a short re-snapshot interval by exporting one variable
    /// to the wrapper. Explicit `env` entries win over both.
    static func paddock(socket: String, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SOCKET_PATH"] = socket
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PADDOCK_HERDR_BIN", "PADDOCK_RESNAPSHOT_SECONDS"] {
            if let value = inherited[key], !value.isEmpty {
                app.launchEnvironment[key] = value
            }
        }
        for (key, value) in env {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// SwiftUI decides for itself which element type carries a view's
    /// accessibility identifier, and that decision differs by view and by
    /// release, so lookups search the whole tree instead of naming a type.
    func paddockElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func paddockElementCount(identifierPrefix: String) -> Int {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .count
    }
}

/// Presses the source element and drags it onto the target, aiming at one of
/// the target's edges when `toEdge` is given and at its middle otherwise.
///
/// This synthesizes real mouse events: it takes over the machine's pointer for
/// the length of the drag, and anything else using the pointer at the same
/// time corrupts the gesture.
@MainActor
func dragElement(_ app: XCUIApplication, fromID: String, toID: String, toEdge: Edge? = nil, pressDuration: TimeInterval = 0.3) {
    let source = app.paddockElement(fromID)
    let target = app.paddockElement(toID)
    let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let to = target.coordinate(withNormalizedOffset: normalizedOffset(for: toEdge))
    from.press(forDuration: pressDuration, thenDragTo: to)
}

/// An edge aim lands one twentieth of the target's own size inside it, which
/// is inside the edge band the drop resolver reads and clear of the target's
/// boundary with its neighbor.
private func normalizedOffset(for edge: Edge?) -> CGVector {
    let inset = 0.05
    switch edge {
    case .none: return CGVector(dx: 0.5, dy: 0.5)
    case .left: return CGVector(dx: inset, dy: 0.5)
    case .right: return CGVector(dx: 1 - inset, dy: 0.5)
    case .top: return CGVector(dx: 0.5, dy: inset)
    case .bottom: return CGVector(dx: 0.5, dy: 1 - inset)
    }
}
