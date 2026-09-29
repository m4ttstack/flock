import Foundation

/// Whether a herdr binary's bytes carry the mouse verbs the patch adds
/// (`terminal.mouse` inbound, `terminal.mouse_capture` outbound). This is the
/// marker flock checks for install detection: read the binary, never run it,
/// since running an unknown herdr build to interrogate it is both slower and
/// riskier than inspecting it.
public enum HerdrMouseVerbs {
    /// The outbound verb, never the inbound one: stock herdr 0.9.2 accepts
    /// `terminal.mouse` but never reports capture, and flock needs both.
    public static let marker = "terminal.mouse_capture"

    public static func present(in data: Data) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }
}
