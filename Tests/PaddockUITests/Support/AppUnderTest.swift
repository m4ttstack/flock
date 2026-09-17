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

/// Where inside an element a drag's press or release lands.
///
/// Every point a drag needs is stated here, in the element's own box, so no
/// case ever computes a screen coordinate of its own.
enum Aim {
    /// The element's middle.
    case middle

    /// One twentieth of the element's own size inside the named edge: inside
    /// the outer fifth the drop resolver reads as that edge (`edgeBandFraction`
    /// in `DropResolver`) and clear of the boundary with the next element.
    case edge(Edge)

    /// A canvas pane cell's at-rest drag handle: the chrome band across the
    /// top of the box. `PaneChrome.contentTop` makes it 28pt deep, and a press
    /// below it belongs to the terminal surface and starts no drag at all
    /// (`PaneGrabRegion`), so a pane cell is the one source that must never be
    /// grabbed in the middle.
    case paneChromeBand

    /// A point stated as a fraction of the element's own box, for a surface
    /// drawn inside an element that carries no identifier of its own. The grid
    /// thumbnail's mini panes are the only such surface a pane drag uses.
    case fraction(x: CGFloat, y: CGFloat)
}

/// What one synthesized drag actually did, for a failure message: a case that
/// aimed at the wrong place and a case whose gesture was ignored fail
/// identically without these.
struct DragTrace: CustomStringConvertible {
    let fromID: String
    let toID: String
    let from: CGPoint
    let to: CGPoint

    var description: String {
        "drag \(fromID) at \(point(from)) -> \(toID) at \(point(to))"
    }

    private func point(_ value: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", value.x, value.y)
    }
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

    /// How many DISTINCT identifiers under the prefix the window is drawing,
    /// which for every caller is how many of the thing there are, because each
    /// one is keyed by its own id.
    func paddockElementCount(identifierPrefix: String) -> Int {
        paddockIdentifiers(prefix: identifierPrefix).count
    }

    /// The identifiers under a prefix that the app is currently showing, for a
    /// failure message that has to say what WAS on screen.
    ///
    /// Read out of ONE captured tree, never off resolved elements. A query
    /// hands back proxies that re-resolve on every attribute read, and the
    /// window redraws from herdr's events between the resolve and the read, so
    /// a proxy for a pane cell the drop has since moved fails the whole test
    /// with "no matches found" rather than reporting that it is gone. A
    /// snapshot is a value: reading it cannot fail, and a capture that cannot
    /// be taken at all reads as an empty window, which a poll treats as
    /// not-yet rather than as a verdict.
    func paddockIdentifiers(prefix: String) -> [String] {
        paddockBoxes(prefix: prefix).keys.sorted()
    }

    /// The same, with each identifier's box. Frames are read from here for the
    /// same reason identifiers are.
    ///
    /// One entry per identifier, and the walk is pre-order, so the entry is
    /// the OUTERMOST node carrying it. That is the right box only while each
    /// identifier belongs to exactly one element, which is what the views
    /// declaring themselves accessibility containers guarantees: undeclared,
    /// SwiftUI folds a container's subtree into its text leaves and stamps the
    /// container's identifier on every one of them. The symptom to watch for
    /// is a box far smaller than the thing it is named for -- a pane cell
    /// reporting a few dozen points in a corner, a card reporting a label --
    /// which means the folding is back and every aim measured against it is
    /// landing somewhere else.
    func paddockBoxes(prefix: String) -> [String: CGRect] {
        guard let tree = try? snapshot() else { return [:] }
        var found: [String: CGRect] = [:]
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix(prefix), found[node.identifier] == nil {
                found[node.identifier] = node.frame
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(tree)
        return found
    }

    /// Every piece of text the element carrying `identifier` draws, its own
    /// and its descendants', from the same single capture everything else is
    /// read from.
    ///
    /// A container's text belongs to its children (that is what declaring one
    /// means), and which child holds a given word is SwiftUI's to decide, so
    /// what a chrome item shows is asked of its whole subtree rather than of
    /// one node. An empty array is "the window is not drawing that item",
    /// which a poll treats as not-yet.
    func paddockText(in identifier: String) -> [String] {
        paddockText(inAnyOf: [identifier])
    }

    /// The same, for several items at once, out of ONE capture. A poll that
    /// watches two places costs what a poll that watches one costs; taking a
    /// tree per identifier would double what the window is asked for on every
    /// iteration of a twenty-second wait.
    func paddockText(inAnyOf identifiers: [String]) -> [String] {
        guard let tree = try? snapshot() else { return [] }
        let wanted = Set(identifiers)
        var text: [String] = []
        func collect(_ node: XCUIElementSnapshot) {
            if !node.label.isEmpty { text.append(node.label) }
            if let value = node.value as? String, !value.isEmpty { text.append(value) }
            for child in node.children {
                collect(child)
            }
        }
        func walk(_ node: XCUIElementSnapshot) {
            if wanted.contains(node.identifier) {
                collect(node)
                return
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(tree)
        return text
    }
}

/// Presses the source element and drags it onto the target.
///
/// This synthesizes real mouse events: it takes over the machine's pointer for
/// the length of the drag, and anything else using the pointer at the same
/// time corrupts the gesture.
///
/// `speed` is for the one gesture a plain press-and-drag cannot express: a
/// dwell needs the pointer still moving while it sits over its target, since
/// `DragController` checks its spring-load deadline from the move events a
/// drag delivers and from nothing else, so a pointer parked dead still never
/// reaches one. A slow crossing of the target provides that.
///
/// A gesture is never interrupted, and nothing here may try: XCTest owns the
/// machine until the button comes up (see the note on `PaneDragTests`).
@MainActor
@discardableResult
func dragElement(
    _ app: XCUIApplication,
    fromID: String,
    grabbing grab: Aim = .paneChromeBand,
    toID: String,
    aiming at: Aim = .middle,
    pressDuration: TimeInterval = 0.3,
    speed: XCUIGestureVelocity = .default
) -> DragTrace {
    let source = app.paddockElement(fromID)
    let target = app.paddockElement(toID)
    XCTAssertTrue(source.exists, "nothing on screen carries \(fromID), so this drag had nothing to grab")
    XCTAssertTrue(target.exists, "nothing on screen carries \(toID), so this drag had nothing to aim at")
    let from = source.coordinate(withNormalizedOffset: .zero).withOffset(offset(grab, in: source.frame))
    let to = target.coordinate(withNormalizedOffset: .zero).withOffset(offset(at, in: target.frame))
    let fromPoint = from.screenPoint
    let toPoint = to.screenPoint

    // The plain two-argument press is the form the closed-loop spike proved;
    // the velocity form is taken only when a case asks for a pace, so the
    // ordinary drags keep the proven path. Neither holds at the target: a held
    // button buys nothing once nothing may happen during the gesture.
    if speed != .default {
        from.press(forDuration: pressDuration, thenDragTo: to, withVelocity: speed, thenHoldForDuration: 0)
    } else {
        from.press(forDuration: pressDuration, thenDragTo: to)
    }
    return DragTrace(fromID: fromID, toID: toID, from: fromPoint, to: toPoint)
}

/// Clicks a point inside an element, stated the same way a drag states its
/// ends. A plain `XCUIElement.click()` always takes the middle, which is the
/// wrong place whenever the middle belongs to a subview with a gesture of its
/// own.
///
/// `modifiers` is held for the length of the click alone: the rail reads the
/// Command state off `NSEvent.modifierFlags` when its tap fires, so a
/// Cmd+click has to arrive as a click with the key actually down rather than
/// as a keystroke beside one.
@MainActor
func clickElement(
    _ app: XCUIApplication, _ identifier: String, at aim: Aim = .middle,
    holding modifiers: XCUIElement.KeyModifierFlags = []
) {
    let element = app.paddockElement(identifier)
    XCTAssertTrue(element.exists, "nothing on screen carries \(identifier), so this click had nothing to hit")
    let point = element.coordinate(withNormalizedOffset: .zero).withOffset(offset(aim, in: element.frame))
    guard !modifiers.isEmpty else {
        point.click()
        return
    }
    XCUIElement.perform(withKeyModifiers: modifiers) {
        point.click()
        // The keys stay down past the click: SwiftUI's tap action runs when
        // the gesture resolves, not when the click event lands, and the rail
        // reads the CURRENT modifier state inside that action. Releasing the
        // key the instant the click returns can leave the action reading no
        // modifier at all, which is a plain click.
        usleep(400_000)
    }
}

/// Double-clicks a point inside an element, which is what opens an inline
/// rename editor on the chrome.
@MainActor
func doubleClickElement(_ app: XCUIApplication, _ identifier: String, at aim: Aim = .middle) {
    let element = app.paddockElement(identifier)
    XCTAssertTrue(element.exists, "nothing on screen carries \(identifier), so this double-click had nothing to hit")
    element.coordinate(withNormalizedOffset: .zero).withOffset(offset(aim, in: element.frame)).doubleClick()
}

/// Right-clicks a point inside an element, for the pane menu. A pane that is
/// not the focused one always answers a right-click with the menu, whatever
/// its program has asked for (`RightClickDisposition.decide`), which is why
/// every menu case here opens it on an unfocused pane.
@MainActor
func rightClickElement(_ app: XCUIApplication, _ identifier: String, at aim: Aim = .middle) {
    let element = app.paddockElement(identifier)
    XCTAssertTrue(element.exists, "nothing on screen carries \(identifier), so this right-click had nothing to hit")
    element.coordinate(withNormalizedOffset: .zero).withOffset(offset(aim, in: element.frame)).rightClick()
}

/// Polls a claim about the window until it holds.
///
/// The window redraws from herdr's events, so nothing it draws is true in the
/// instant a gesture or a click ends. `describing` is evaluated only on the
/// failure, and says what the window was actually showing.
@MainActor
func assertEventually(
    _ what: String, timeout: TimeInterval = 20,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool, describing: @MainActor () -> String
) {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return }
        usleep(200_000)
    } while Date() < deadline
    XCTFail("\(what): not true within \(timeout)s. \(describing())", file: file, line: line)
}

/// Moves the pointer onto an element and leaves it there, which is how a
/// hover-revealed control is made real: it is laid out either way, but it
/// takes no hit until the row under the pointer says it is revealed.
@MainActor
func hoverElement(_ app: XCUIApplication, _ identifier: String, at aim: Aim = .middle) {
    let element = app.paddockElement(identifier)
    XCTAssertTrue(element.exists, "nothing on screen carries \(identifier), so there was nothing to hover")
    element.coordinate(withNormalizedOffset: .zero).withOffset(offset(aim, in: element.frame)).hover()
}

private func offset(_ aim: Aim, in frame: CGRect) -> CGVector {
    switch aim {
    case .middle:
        return CGVector(dx: frame.width / 2, dy: frame.height / 2)
    case .edge(let edge):
        let insetX = frame.width * edgeAimInset
        let insetY = frame.height * edgeAimInset
        switch edge {
        case .left: return CGVector(dx: insetX, dy: frame.height / 2)
        case .right: return CGVector(dx: frame.width - insetX, dy: frame.height / 2)
        case .top: return CGVector(dx: frame.width / 2, dy: insetY)
        case .bottom: return CGVector(dx: frame.width / 2, dy: frame.height - insetY)
        }
    case .paneChromeBand:
        return CGVector(dx: frame.width / 2, dy: paneChromeBandDepth / 2)
    case .fraction(let x, let y):
        return CGVector(dx: frame.width * x, dy: frame.height * y)
    }
}

/// How far inside an edge an `.edge` aim lands, as a fraction of the target's
/// own size. Inside `DropResolver.edgeBandFraction` (a fifth) with room to
/// spare, and off the boundary the target shares with its neighbor.
private let edgeAimInset: CGFloat = 0.05

/// `PaneChrome.contentTop`: 10pt of padding, a 14pt title row, a 4pt gap. Not
/// importable here (the UI test bundle links the app, not PaddockCore), so it
/// is restated -- a canvas pane grabbed below this band starts no drag.
private let paneChromeBandDepth: CGFloat = 28
