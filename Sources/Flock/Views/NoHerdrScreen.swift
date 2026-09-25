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

    struct Copy {
        let headline: String
        let body: String
        let hint: String
    }

    static let missing = Copy(
        headline: "You can't have a flock without a herdr!",
        body: "flock couldn't find herdr on this Mac, so there is nothing to drive a pane with.",
        hint: "Install herdr, then relaunch flock."
    )
    static let notRunning = Copy(
        headline: "Oops! Doesn't look like herdr has started.",
        body: "flock shows your herdr session, and no herdr server is running yet.",
        hint: "Start it here, or run herdr in a terminal."
    )

    static var headline: String { missing.headline }
    static var body: String { missing.body }
    static var hint: String { missing.hint }

    let theme: Theme
    var copy: Copy = Self.missing
    var primaryAction: PrimaryAction?

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
            Text(copy.hint)
                .font(ChromeType.noHerdrHint)
                .foregroundStyle(theme.textLabel)
                .multilineTextAlignment(.center)
            if let primaryAction {
                Button(primaryAction.title, action: primaryAction.perform)
                    .buttonStyle(PrimaryActionStyle(theme: theme))
                    .disabled(primaryAction.isDisabled)
                    .padding(.top, ChromeMetrics.NoHerdr.primaryActionTopPadding)
                    .accessibilityIdentifier("flock.noHerdr.primaryAction")
            }
        }
        .padding(.horizontal, ChromeMetrics.NoHerdr.horizontalPadding)
    }
}

/// The theme's accent whatever the window's state: `.borderedProminent`
/// greys out in a window that is not key, which a screen with one thing to
/// do cannot afford.
private struct PrimaryActionStyle: ButtonStyle {
    let theme: Theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.noHerdrAction)
            // The chrome ground on the accent: dark on a dark theme's pale
            // accent, near white on a light theme's deep one.
            .foregroundStyle(theme.chrome)
            .padding(.horizontal, ChromeMetrics.NoHerdr.actionHorizontalPadding)
            .frame(height: ChromeMetrics.NoHerdr.actionHeight)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.NoHerdr.actionCornerRadius)
                    .fill(theme.accent)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}
