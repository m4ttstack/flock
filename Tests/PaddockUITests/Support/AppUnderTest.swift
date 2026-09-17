import AppKit
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
    /// Whether the `whileHeld` work ran before the button came up. False means
    /// the interjection never happened, so whatever it was meant to cause
    /// cannot be read into the result.
    let heldWorkRan: Bool

    var description: String {
        "drag \(fromID) at \(point(from)) -> \(toID) at \(point(to))"
            + (heldWorkRan ? ", held work ran" : "")
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

    func paddockElementCount(identifierPrefix: String) -> Int {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .count
    }

    /// The identifiers under a prefix that the app is currently showing, for a
    /// failure message that has to say what WAS on screen.
    ///
    /// Bound in one pass rather than counted and then indexed: the window
    /// redraws from herdr's events, so a count taken before a redraw and an
    /// index resolved after it fail the test with "no matches found" instead
    /// of reporting what changed.
    func paddockIdentifiers(prefix: String) -> [String] {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByAccessibilityElement
            .map(\.identifier)
            .sorted()
    }
}

/// Makes the app under test resign active, which its drag layer reads as a
/// gesture that will never see a release and tears down, committing nothing.
///
/// This is how a drag is ended mid-gesture. Escape, which the drag's own key
/// monitor also treats as a cancel, cannot be sent from here at all: XCTest
/// arbitrates its own event synthesis and refuses a keystroke while a gesture
/// it started is still running ("Unable to synthesize gesture request N ...
/// because gesture request M is still in progress"), retrying until the
/// gesture is over and the button is already up. Activating the runner is not
/// event synthesis, so it is not arbitrated.
@MainActor
func takeFocusFromTheAppUnderTest() {
    NSRunningApplication.current.activate()
}

/// Presses the source element and drags it onto the target.
///
/// This synthesizes real mouse events: it takes over the machine's pointer for
/// the length of the drag, and anything else using the pointer at the same
/// time corrupts the gesture.
///
/// `speed` and `hold` exist for the two gestures a plain press-and-drag cannot
/// express. A dwell needs the pointer still moving while it sits over its
/// target -- `DragController` checks its spring-load deadline from the move
/// events a drag delivers and from nothing else, so a pointer parked dead
/// still never reaches one -- which a slow crossing of the target provides. A
/// drag that ends without committing needs something done while the button is
/// still down, which is what `whileHeld` runs in.
///
/// `whileHeld` runs on the main queue, which the blocked gesture call does
/// give a turn (proven live). What it must NOT do is ask XCTest to synthesize
/// anything: see `takeFocusFromTheAppUnderTest`.
@MainActor
@discardableResult
func dragElement(
    _ app: XCUIApplication,
    fromID: String,
    grabbing grab: Aim = .paneChromeBand,
    toID: String,
    aiming at: Aim = .middle,
    pressDuration: TimeInterval = 0.3,
    speed: XCUIGestureVelocity = .default,
    hold: TimeInterval = 0,
    whileHeld: (@MainActor @Sendable () -> Void)? = nil
) -> DragTrace {
    let source = app.paddockElement(fromID)
    let target = app.paddockElement(toID)
    XCTAssertTrue(source.exists, "nothing on screen carries \(fromID), so this drag had nothing to grab")
    XCTAssertTrue(target.exists, "nothing on screen carries \(toID), so this drag had nothing to aim at")
    let from = source.coordinate(withNormalizedOffset: .zero).withOffset(offset(grab, in: source.frame))
    let to = target.coordinate(withNormalizedOffset: .zero).withOffset(offset(at, in: target.frame))
    let fromPoint = from.screenPoint
    let toPoint = to.screenPoint

    let ran = HeldWorkFlag()
    if let whileHeld {
        // Scheduled before the gesture rather than inside it: the gesture call
        // blocks this thread until the button comes up, so the only turn the
        // interjection can get is one the gesture's own run loop gives it.
        // Timed from the press through the travel the velocity implies, into
        // the hold that follows it.
        let travel = hypot(toPoint.x - fromPoint.x, toPoint.y - fromPoint.y) / max(speed.rawValue, 1)
        let fireAt = pressDuration + travel + max(0.1, min(0.3, hold * 0.4))
        DispatchQueue.main.asyncAfter(deadline: .now() + fireAt) {
            MainActor.assumeIsolated {
                whileHeld()
                ran.value = true
            }
        }
    }

    // The plain two-argument press is the form the closed-loop spike proved;
    // the velocity form is taken only when a case actually asks for a pace or
    // a hold, so the ordinary drags keep the proven path.
    if hold > 0 || speed != .default {
        from.press(forDuration: pressDuration, thenDragTo: to, withVelocity: speed, thenHoldForDuration: hold)
    } else {
        from.press(forDuration: pressDuration, thenDragTo: to)
    }
    return DragTrace(fromID: fromID, toID: toID, from: fromPoint, to: toPoint, heldWorkRan: ran.value)
}

/// Clicks a point inside an element, stated the same way a drag states its
/// ends. A plain `XCUIElement.click()` always takes the middle, which is the
/// wrong place whenever the middle belongs to a subview with a gesture of its
/// own.
@MainActor
func clickElement(_ app: XCUIApplication, _ identifier: String, at aim: Aim = .middle) {
    let element = app.paddockElement(identifier)
    XCTAssertTrue(element.exists, "nothing on screen carries \(identifier), so this click had nothing to hit")
    element.coordinate(withNormalizedOffset: .zero).withOffset(offset(aim, in: element.frame)).click()
}

/// Written on the main actor by the interjection and read on it by the drag
/// helper, which is the only reason it is a reference at all.
@MainActor
private final class HeldWorkFlag {
    var value = false
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
