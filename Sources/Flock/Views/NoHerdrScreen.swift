import FlockCore
import SwiftUI

/// Shown instead of `MainWindow` when `HerdrAvailability.shouldShowMissingScreen`
/// says herdr is not on this Mac: every pane flock draws is a herdr bridge, so
/// a machine without it has nothing else to show.
///
/// `primaryAction` is nil at every call site today. It exists so that once
/// flock can patch a user's own herdr, that action has a slot to land in
/// without reshaping this view -- the button itself is not built yet, since
/// there is nothing for it to trigger.
struct NoHerdrScreen: View {
    struct PrimaryAction {
        let title: String
        let perform: () -> Void
    }

    static let headline = "You can't have a flock without a herdr!"
    static let body = "flock couldn't find herdr on this Mac, so there is nothing to drive a pane with."
    static let hint = "Install herdr, then relaunch flock."

    let theme: Theme
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
                Text(Self.headline)
                    .font(ChromeType.noHerdrHeadline)
                    .foregroundStyle(theme.textStrong)
                    .multilineTextAlignment(.center)
            }
            Text(Self.body)
                .font(ChromeType.noHerdrBody)
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
            Text(Self.hint)
                .font(ChromeType.noHerdrHint)
                .foregroundStyle(theme.textLabel)
                .multilineTextAlignment(.center)
            if let primaryAction {
                Button(primaryAction.title, action: primaryAction.perform)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, ChromeMetrics.NoHerdr.primaryActionTopPadding)
                    .accessibilityIdentifier("flock.noHerdr.primaryAction")
            }
        }
        .padding(.horizontal, ChromeMetrics.NoHerdr.horizontalPadding)
    }
}
