import Foundation

/// Whether a herdr binary's bytes carry the mouse verbs the patch adds
/// (`terminal.mouse` inbound, `terminal.mouse_capture` outbound). This is the
/// marker flock checks for install detection: read the binary, never run it,
/// since running an unknown herdr build to interrogate it is both slower and
/// riskier than inspecting it.
public enum HerdrMouseVerbs {
    /// The shorter of the two verb names; every occurrence of the longer one
    /// contains this as a prefix, so one substring search covers both.
    public static let marker = "terminal.mouse"

    public static func present(in data: Data) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }
}
