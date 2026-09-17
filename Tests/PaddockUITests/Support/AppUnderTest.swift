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
    /// What the out-of-process interruption reported, or nil when the drag
    /// asked for none. A case that reads a teardown into its result has to
    /// know the interruption actually happened: a drag that was never
    /// interrupted and a drag the app never saw look the same afterward.
    let interruption: String?

    var description: String {
        "drag \(fromID) at \(point(from)) -> \(toID) at \(point(to))"
            + (interruption.map { ", interruption \($0)" } ?? "")
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
}

/// Starts a detached helper that brings another application forward after
/// `delay`. The app under test resigning active is what its drag layer reads
/// as a gesture that will never see a release, and it tears the drag down
/// without committing.
///
/// The delay runs in a process of its own because nothing inside this one can
/// be relied on to act while a gesture is in flight: XCTest refuses to
/// synthesize a keystroke until its own gesture finishes, and the thread it
/// blocks does not reliably turn the main run loop either -- across two runs
/// the same main-queue interjection ran during a long drag and never ran
/// during a short one. A separate process is subject to neither.
func scheduleDeactivationOfTheAppUnderTest(after delay: TimeInterval) -> Process? {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    // LaunchServices rather than an Apple event: the runner is sandboxed, so
    // anything it spawns is too, and a sandboxed process scripting another app
    // needs an entitlement it does not have. Activating the runner itself is
    // not an option either -- it has no window, and macOS does not bring a
    // windowless app forward, which is why the previous attempt reported
    // having run and changed nothing.
    helper.arguments = [
        "-c", "sleep \(String(format: "%.2f", delay)); exec /usr/bin/open -b \(frontmostDuringAnInterruption)",
    ]
    let errors = Pipe()
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = errors
    do {
        try helper.run()
    } catch {
        return nil
    }
    helperErrors[ObjectIdentifier(helper)] = errors
    return helper
}

/// What that helper reported once it is done, for the drag's trace. Read after
/// the gesture, which the helper always finishes inside.
func deactivationOutcome(of helper: Process?) -> String {
    guard let helper else { return "could not be started" }
    let errors = helperErrors.removeValue(forKey: ObjectIdentifier(helper))
    let text = errors.flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) } ?? ""
    helper.waitUntilExit()
    guard helper.terminationStatus == 0 else {
        return "failed (exit \(helper.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    return "ran"
}

/// Finder: always running, always has the desktop to come forward with, and
/// needs no permission to open. The case puts the app under test back in front
/// immediately afterward.
private let frontmostDuringAnInterruption = "com.apple.finder"

/// The helpers' stderr pipes, held until the outcome is read: a `Process` has
/// nowhere to keep one, and a pipe released early closes the read end while
/// the helper is still writing.
private nonisolated(unsafe) var helperErrors: [ObjectIdentifier: Pipe] = [:]

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
/// still never reaches one -- which a slow crossing of the target provides.
///
/// `interruptedMidHold` is for a drag that must end without committing: it
/// starts the helper BEFORE the gesture, timed through the press and the
/// travel the velocity implies, so the app under test resigns active while the
/// button is still down. See `scheduleDeactivationOfTheAppUnderTest` for why
/// it cannot be done from inside this process.
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
    interruptedMidHold: Bool = false
) -> DragTrace {
    let source = app.paddockElement(fromID)
    let target = app.paddockElement(toID)
    XCTAssertTrue(source.exists, "nothing on screen carries \(fromID), so this drag had nothing to grab")
    XCTAssertTrue(target.exists, "nothing on screen carries \(toID), so this drag had nothing to aim at")
    let from = source.coordinate(withNormalizedOffset: .zero).withOffset(offset(grab, in: source.frame))
    let to = target.coordinate(withNormalizedOffset: .zero).withOffset(offset(at, in: target.frame))
    let fromPoint = from.screenPoint
    let toPoint = to.screenPoint

    var helper: Process?
    if interruptedMidHold {
        let travel = hypot(toPoint.x - fromPoint.x, toPoint.y - fromPoint.y) / max(speed.rawValue, 1)
        helper = scheduleDeactivationOfTheAppUnderTest(after: pressDuration + travel + max(0.1, min(0.3, hold * 0.4)))
    }

    // The plain two-argument press is the form the closed-loop spike proved;
    // the velocity form is taken only when a case actually asks for a pace or
    // a hold, so the ordinary drags keep the proven path.
    if hold > 0 || speed != .default {
        from.press(forDuration: pressDuration, thenDragTo: to, withVelocity: speed, thenHoldForDuration: hold)
    } else {
        from.press(forDuration: pressDuration, thenDragTo: to)
    }
    return DragTrace(
        fromID: fromID, toID: toID, from: fromPoint, to: toPoint,
        interruption: interruptedMidHold ? deactivationOutcome(of: helper) : nil
    )
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
