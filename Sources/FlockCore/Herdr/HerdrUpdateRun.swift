import Foundation

/// flock running `herdr update --handoff` itself. With stdin not a terminal,
/// herdr takes its non-interactive paths: a prompt it cannot ask becomes an
/// error exit or a "no", never a wait.
public enum HerdrUpdateRun {
    public static let arguments = ["update", "--handoff"]

    public static let buttonTitle = "Update herdr"
    public static let progressTitle = "Updating herdr..."
    public static let pillTitle = "Updating herdr"

    public enum Outcome: Equatable, Sendable {
        case updated
        case failed(String)
    }

    public static func confirmation(for notice: HerdrUpdateNotice) -> HerdrMousePatchCopy.Confirmation {
        let latest = switch notice {
        case .available(let latest, _, _, _), .breaksMouse(let latest, _, _): latest
        }
        var message = "flock runs herdr update --handoff. Your panes keep running; Flock restarts afterwards to reconnect them."
        if notice.isWarning {
            message += " Mouse support turns off until a flock update adds a patch for \(latest)."
        }
        return HerdrMousePatchCopy.Confirmation(
            title: "Update herdr to \(latest)?", message: message, confirmButtonTitle: "Update"
        )
    }

    /// herdr ends every failure on one line, prefixed `update failed: ` unless
    /// it is a package-manager refusal; the prefix would only repeat the
    /// sentence it is quoted into.
    public static func outcome(status: Int32, output: String) -> Outcome {
        guard status != 0 else { return .updated }
        let last = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard var line = last else { return .failed("herdr couldn't update: it exited with status \(status)") }
        let prefix = "update failed: "
        if line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        return .failed("herdr couldn't update: \(line)")
    }
}
