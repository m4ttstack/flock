import FlockCore
import SwiftUI

/// Shown instead of `MainWindow` when flock has no herdr to drive: none on
/// this Mac (`HerdrAvailability.shouldShowMissingScreen`), or none running.
/// Every pane flock draws is a herdr bridge, so either way there is nothing
/// else to show.
struct NoHerdrScreen: View {
    struct PrimaryAction {
        let title: String
        var isDisabled = false
        let perform: () -> Void
    }

    struct Copy: Equatable {
        let headline: String
        let body: String
        let hint: String
    }

    static let missing = Copy(
        headline: "You can't have a flock without a herdr!",
        body: "flock couldn't find herdr on this Mac, so there is nothing to drive a pane with.",
        hint: HerdrBuildCopy.missingHint
    )
    static let notRunning = Copy(
        headline: "Oops! Doesn't look like herdr has started.",
        body: "flock shows your herdr session, and no herdr server is running yet.",
        hint: "Start it here, or run herdr in a terminal."
    )

    static let missingInstalled = Copy(
        headline: HerdrBuildCopy.missingInstalledHeadline, body: HerdrBuildCopy.missingInstalledBody, hint: ""
    )

    static func notRunning(for address: HerdrServerAddress, isOverride: Bool) -> Copy {
        switch address {
        case .defaultServer:
            return notRunning
        case .named(let name):
            return Copy(
                headline: "The herdr server \u{201C}\(name)\u{201D} isn't running.",
                body: "flock is checking for it and will attach as soon as it starts.",
                hint: "Start it here, or run herdr --session \(name) in a terminal."
            )
        case .custom(let path):
            return Copy(
                headline: "Nothing is answering at \(path).",
                body: "flock is checking and will attach as soon as a herdr server is listening there.",
                hint: isOverride
                    ? "Start it here, or start that server however it is normally started."
                    : "Start that server however it is normally started."
            )
        }
    }

    /// Nil means no button: flock starts a custom path's server only under
    /// an override.
    static func startTitle(for address: HerdrServerAddress, isOverride: Bool, isStarting: Bool) -> String? {
        if case .custom = address, !isOverride { return nil }
        return isStarting ? "Starting herdr\u{2026}" : "Start herdr"
    }

    static var headline: String { missing.headline }
    static var body: String { missing.body }
    static var hint: String { missing.hint }

    let theme: Theme
    var copy: Copy = Self.missing
    var primaryAction: PrimaryAction?
    /// Under the button: why its last press did not land.
    var errorMessage: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.chrome)
            // Must match `MainWindow`'s own floor: the window must not
            // visibly resize when herdr appears and this screen is replaced
            // by the session window.
            .frame(minWidth: 900, minHeight: 560)
            .ignoresSafeArea(edges: .top)
            .background(TitlebarConfigurator(windowBg: theme.chrome))
            .accessibilityIdentifier("flock.noHerdr.screen")
    }

    /// Split from `body` so a test can measure this stack's own ideal size
    /// rather than the outer 900x560 floor, which would swallow any growth
    /// `primaryAction` adds.
    var content: some View {
        VStack(spacing: ChromeMetrics.NoHerdr.spacing) {
            VStack(spacing: ChromeMetrics.NoHerdr.symbolSpacing) {
                HerdrRamMark(size: ChromeMetrics.NoHerdr.markSize)
                Text(copy.headline)
                    .font(ChromeType.noHerdrHeadline)
                    .foregroundStyle(theme.textStrong)
                    .multilineTextAlignment(.center)
            }
            Text(copy.body)
                .font(ChromeType.noHerdrBody)
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
            if !copy.hint.isEmpty {
                Text(copy.hint)
                    .font(ChromeType.noHerdrHint)
                    .foregroundStyle(theme.textLabel)
                    .multilineTextAlignment(.center)
            }
            if let primaryAction {
                Button(primaryAction.title, action: primaryAction.perform)
                    .buttonStyle(NoHerdrPrimaryActionStyle(theme: theme))
                    .disabled(primaryAction.isDisabled)
                    .padding(.top, ChromeMetrics.NoHerdr.primaryActionTopPadding)
                    .accessibilityIdentifier("flock.noHerdr.primaryAction")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(ChromeType.noHerdrHint)
                    .foregroundStyle(theme.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("flock.noHerdr.error")
            }
        }
        .padding(.horizontal, ChromeMetrics.NoHerdr.horizontalPadding)
    }
}

/// The screen for no herdr on this Mac. Its button installs the newest
/// mattstack build at once: pressing it is the consent, since nothing on
/// disk is replaced. An install that put herdr on disk and still failed says
/// so here until Continue.
struct MissingHerdrScreen: View {
    let theme: Theme
    let store: HerdrBuildStore

    var body: some View {
        NoHerdrScreen(theme: theme, copy: copy, primaryAction: action, errorMessage: errorMessage)
    }

    var copy: NoHerdrScreen.Copy {
        store.installedWithError == nil ? NoHerdrScreen.missing : NoHerdrScreen.missingInstalled
    }

    var action: NoHerdrScreen.PrimaryAction {
        if store.installedWithError != nil {
            return .init(title: HerdrBuildCopy.missingContinueTitle, perform: store.dismissMissingInstall)
        }
        let busy = store.phase != .idle
        var installable = false
        if case .missing = store.state { installable = true }
        return .init(
            title: busy ? HerdrBuildCopy.missingInstallingTitle : HerdrBuildCopy.missingInstallTitle,
            isDisabled: busy || !installable,
            perform: { store.installMissing(source: .missingScreen) }
        )
    }

    var errorMessage: String? {
        if let message = store.installedWithError ?? store.lastErrorMessage { return message }
        guard let state = store.state, case .notWritable = state else { return nil }
        return HerdrBuildCopy.body(for: state)
    }
}

/// The theme's accent whatever the window's state: `.borderedProminent`
/// greys out in a window that is not key, which a screen with one thing to
/// do cannot afford.
struct NoHerdrPrimaryActionStyle: ButtonStyle {
    let theme: Theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.noHerdrAction)
            // The chrome ground on the accent: dark on a dark theme's pale
            // accent, near white on a light theme's deep one. Disabled, the
            // title is the only word on progress, so it stays legible on a
            // faint wash rather than fading with the fill.
            .foregroundStyle(isEnabled ? theme.chrome : theme.textDim)
            .padding(.horizontal, ChromeMetrics.NoHerdr.actionHorizontalPadding)
            .frame(height: ChromeMetrics.NoHerdr.actionHeight)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.NoHerdr.actionCornerRadius)
                    .fill(theme.accent.opacity(isEnabled ? 1 : 0.2))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .contentShape(Rectangle())
    }
}
