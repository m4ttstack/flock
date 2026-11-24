import Foundation

/// The settings row's text, one state at a time.
public enum HerdrBuildCopy {
    public static let heading = "herdr"
    public static let rowTitle = "mattstack build"

    public static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    public static func body(for state: HerdrBuildState) -> String {
        switch state {
        case .missing(let installPath):
            return "Not installed. flock can install herdr to \(displayPath(installPath))."
        case .stock(_, _, let newest):
            return "This herdr isn't the mattstack build, so clicks, scrolling and themes don't reach your panes. "
                + "flock can put herdr \(newest) in its place."
        case .outdated(_, let installed, let newest):
            return "herdr \(newest) is available. flock can replace \(installed ?? "this build") with it."
        case .current:
            return "Up to date."
        case .notWritable(let installPath):
            return "flock can't write to \(displayPath(installPath)) from this account, so it leaves herdr alone."
        case .listUnavailable:
            return "flock couldn't read the herdr build list, so it can't check for a newer build."
        }
    }

    public static func actionTitle(for state: HerdrBuildState) -> String? {
        switch state {
        case .missing, .stock: "Install"
        case .outdated: "Update"
        case .current, .notWritable, .listUnavailable: nil
        }
    }

    public struct Confirmation: Equatable, Sendable {
        public let title: String
        public let message: String
        public let confirmButtonTitle: String
    }

    public static func installConfirmation(installPath: String, newest: String) -> Confirmation {
        Confirmation(
            title: "Install herdr \(newest)?",
            message: "flock will replace \(displayPath(installPath)) with herdr \(newest), the mattstack build, "
                + "once its download matches the build list.",
            confirmButtonTitle: "Install"
        )
    }

    public static func updateConfirmation(installPath: String, newest: String) -> Confirmation {
        Confirmation(
            title: "Update herdr to \(newest)?",
            message: "flock will replace \(displayPath(installPath)) with herdr \(newest) once its download "
                + "matches the build list.",
            confirmButtonTitle: "Update"
        )
    }

    /// `serverBehind` is raised by no change at all: the server was found on
    /// an older binary than the one on disk.
    public enum RestartReason: Equatable, Sendable {
        case installed, updated, serverBehind
    }

    public static func restartHeadline(for reason: RestartReason) -> String {
        switch reason {
        case .installed: "herdr is installed"
        case .updated: "herdr is updated"
        case .serverBehind: "herdr's server is out of date"
        }
    }

    /// `restartsServer`: the server runs an older binary than the one on
    /// disk, so restarting Flock alone would leave the build half applied.
    public static func restartDetail(for reason: RestartReason, restartsServer: Bool = false) -> String {
        if reason == .serverBehind { return "A restart keeps your panes running." }
        if restartsServer { return "Restart herdr to finish; panes keep running." }
        return "Restart Flock so your panes pick it up."
    }

    public static let restartActionTitle = "Restart Flock"
    public static let serverRestartActionTitle = "Restart herdr"
    public static let serverRestartProgressTitle = "Restarting herdr..."

    public static func restartActionTitle(restartsServer: Bool) -> String {
        restartsServer ? serverRestartActionTitle : restartActionTitle
    }

    /// A live handoff: herdr passes every pane to a new server on the binary
    /// on disk, so nothing in a pane is restarted. Flock restarts afterwards
    /// because the handoff drops every pane's bridge.
    public static let serverRestartConfirmation = Confirmation(
        title: "Restart herdr's server?",
        message: "flock hands your panes to a new herdr server running the build on disk, then restarts Flock to "
            + "reconnect them. Shells and agents keep running. A program that already picked light or dark keeps "
            + "it until it checks again.",
        confirmButtonTitle: "Restart"
    )

    public static let serverRestartFailedBanner = "herdr's server didn't restart; see Settings."

    public static func serverRestartFailure(_ reason: String) -> String {
        "\(reason) To finish by hand, run herdr server stop in a terminal, then reopen Flock. That ends every "
            + "pane's shell and agent."
    }

    public static let missingHint = "flock can install the mattstack build of herdr for you."
    public static let missingInstallTitle = "Install herdr"
    public static let missingInstallingTitle = "Installing herdr\u{2026}"

    public static let downloadFailed = "Couldn't download herdr. Check your connection and try again."
    public static let checksumMismatch = "The download didn't match the build list. Nothing was changed."
    public static let listUnreadable = "flock couldn't read the herdr build list. Check your connection and try again."
    public static let herdrChanged = "herdr changed while the new build downloaded. Nothing was changed."
    public static let notWritable = "herdr's install location is not writable."
    public static let renameFailed = "The file move failed partway through."
    public static let integrationFailed =
        "herdr is installed, but its Claude integration didn't install. Run herdr integration install claude in a terminal."

    /// A machine session's herdr is that machine's, which this Mac's
    /// Settings cannot update.
    public static func protocolTooOld(found: Int, required: Int, onMachine: Bool) -> String {
        let lead = "herdr is too old for flock (found protocol \(found), need \(required))."
        return lead + (onMachine ? " Update herdr on that machine." : " Update it in Settings.")
    }

    public static let protocolTooOldActionTitle = "Open Settings"

    public static func pillTitle(newest: String) -> String { "herdr \(newest)" }
    public static let pillHelp = "A newer herdr is available. Open Settings to update."
}
