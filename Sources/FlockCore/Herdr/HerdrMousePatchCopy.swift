import Foundation

/// The row's text, one state at a time. Never says "upgrade herdr" or
/// implies the maintainers endorsed this: it states plainly that flock
/// replaces the binary with a build of the same version, keeps a backup, and
/// that it can be undone.
public enum HerdrMousePatchCopy {
    public static let heading = "herdr"
    /// The row's own label, distinct from the section heading above it: the
    /// section names the tool, the row names which of its capabilities.
    public static let rowTitle = "Mouse support"

    /// A path under the user's home as `~/...`, which is how a settings row
    /// can show it on one line.
    public static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    public static func body(for state: HerdrMousePatchRowState) -> String {
        switch state {
        case .supportedByHerdr:
            return "On. This herdr passes clicks and scrolling through to panes on its own."
        case .installed(let backupPath):
            return "On. flock installed a build of your herdr version that passes clicks and scrolling through "
                + "to your panes. Your original herdr is saved at \(displayPath(backupPath))."
        case .outdated(_, let version, _, let backupPath):
            return "On, with an older build. flock has a newer build of herdr \(version) that also lets programs "
                + "in your panes follow your light or dark theme. Your original herdr is saved at "
                + "\(displayPath(backupPath))."
        case .patchable(_, let version):
            return "Off. herdr \(version) doesn't pass clicks and scrolling through to panes. flock can "
                + "install a build of the same version that does, and keep your original to restore later."
        case .notWritable(let installPath):
            return "Off. flock can't write to \(displayPath(installPath)) from this account, so it leaves herdr alone."
        case .unsupportedVersion:
            return "Not available. flock has no mouse patch for this herdr. If it's newer than herdr "
                + "\(HerdrMousePatchVersion.supported.last ?? ""), a flock update will add one."
        }
    }

    /// Every pane's bridge is a herdr process started from the binary that was
    /// on disk at launch, so a swap only reaches panes once Flock restarts.
    /// `herdrUpdated` is the same restart for a different reason: `--handoff`
    /// starts a new server while every bridge still talks to the old one, so
    /// it is raised the moment the handoff lands, before any reinstall.
    /// `serverBehind` is raised by no change at all: the server was found on
    /// an older binary than the patched one on disk (`HerdrServerRestart`).
    public enum RestartReason: Equatable, Sendable {
        case installed, updated, restored
        case herdrUpdated(PatchAfterUpdate)
        case serverBehind
    }

    /// `untouched`: flock's patch was not on the replaced herdr, or there is
    /// no patch for the new one, so the update put nothing back.
    public enum PatchAfterUpdate: Equatable, Sendable {
        case untouched, reinstalling, reinstalled, reinstallFailed
    }

    public static func restartHeadline(for reason: RestartReason) -> String {
        switch reason {
        case .installed: "Mouse support is installed"
        case .updated: "Mouse support is updated"
        case .restored: "The original herdr is restored"
        case .herdrUpdated(.reinstalled): "herdr is updated and mouse support reinstalled"
        case .herdrUpdated: "herdr is updated"
        case .serverBehind: "herdr's server is on an older build"
        }
    }

    /// `restartsServer`: the server runs an older binary than the patched one
    /// on disk, so restarting Flock alone would leave the patch half applied.
    public static func restartDetail(for reason: RestartReason, restartsServer: Bool = false) -> String {
        switch reason {
        case .herdrUpdated(.reinstalling): return "Reinstalling mouse support, then restart Flock so your panes reconnect."
        case .herdrUpdated(.reinstallFailed): return "Mouse support couldn't be reinstalled; see Settings."
        default: break
        }
        if reason == .serverBehind { return "Restarting it keeps your panes running." }
        if restartsServer { return "Restart herdr to finish; panes keep running." }
        switch reason {
        case .herdrUpdated: return "Restart Flock so your panes reconnect."
        default: return "Restart Flock so your panes pick it up."
        }
    }

    /// A restart mid-reinstall would come back without the patch the update
    /// promised to put back.
    public static func offersRestart(for reason: RestartReason) -> Bool {
        reason != .herdrUpdated(.reinstalling)
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

    /// The banner's one line has no room for the way to finish by hand.
    public static let serverRestartFailedBanner = "herdr's server didn't restart; see Settings."

    /// The handoff refused or failed, which leaves the old server running.
    /// Stopping it by hand is the way left, and that one does end every pane.
    public static func serverRestartFailure(_ reason: String) -> String {
        "\(reason) To finish by hand, run herdr server stop in a terminal, then reopen Flock. That ends every "
            + "pane's shell and agent."
    }

    public static func actionTitle(for state: HerdrMousePatchRowState) -> String? {
        switch state {
        case .patchable: return "Install"
        case .outdated: return "Update"
        case .installed: return "Restore Original"
        case .supportedByHerdr, .notWritable, .unsupportedVersion: return nil
        }
    }

    /// An outdated patch keeps Restore beside Update, so the original stays
    /// one click away while the newer build is on offer.
    public static func secondaryActionTitle(for state: HerdrMousePatchRowState) -> String? {
        if case .outdated = state { return "Restore Original" }
        return nil
    }

    /// The single confirmation install always asks, naming the exact path
    /// being replaced. Never remembered as a preference: this is built to be
    /// shown every time, not gated behind a "don't ask again" flag.
    public struct Confirmation: Equatable, Sendable {
        public let title: String
        public let message: String
        public let confirmButtonTitle: String
    }

    public static func installConfirmation(installPath: String, version: String) -> Confirmation {
        Confirmation(
            title: "Install mouse support?",
            message: "flock will replace \(displayPath(installPath)) with a build of herdr "
                + "\(version) that passes clicks and scrolling through to panes. Your "
                + "original is saved beside it and can be restored here.",
            confirmButtonTitle: "Install"
        )
    }

    public static func updateConfirmation(installPath: String, version: String) -> Confirmation {
        Confirmation(
            title: "Update mouse support?",
            message: "flock will replace \(displayPath(installPath)) with a newer build of herdr \(version) that "
                + "also lets programs in your panes follow your light or dark theme. Your original stays saved "
                + "beside it and can be restored here.",
            confirmButtonTitle: "Update"
        )
    }

    public static func revertConfirmation(installPath: String) -> Confirmation {
        Confirmation(
            title: "Restore the original herdr?",
            message: "flock will put back the herdr it saved at "
                + "\(displayPath(HerdrMousePatchInstaller.backupPath(for: installPath))), then delete the saved "
                + "copy once the restore checks out.",
            confirmButtonTitle: "Restore"
        )
    }
}
