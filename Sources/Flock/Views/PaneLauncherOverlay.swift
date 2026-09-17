import FlockCore
import SwiftUI

/// One CLI agent harness `HarnessRoster` knows how to launch. `mark` is the
/// vendor's own published mark (see `Resources/HarnessMarks/README.md` for
/// each one's source and terms); an entry without one falls back to the
/// monogram badge, which is what keeps the roster extensible.
struct HarnessEntry: Identifiable, Equatable {
    let id: String
    let binary: String
    let displayName: String
    let monogram: String
    let monogramColor: Color
    var mark: HarnessMark?
}

/// Every harness flock knows how to offer, resolved against PATH at
/// launcher-render time. Extend `known` to add one; PATH resolution alone
/// decides what actually renders for a given machine.
enum HarnessRoster {
    static let known: [HarnessEntry] = [
        HarnessEntry(
            id: "claude", binary: "claude", displayName: "claude", monogram: "C",
            monogramColor: .init(red: 0.82, green: 0.51, blue: 0.31), mark: .claude
        ),
        HarnessEntry(
            id: "codex", binary: "codex", displayName: "codex", monogram: "X",
            monogramColor: .init(red: 0.29, green: 0.56, blue: 0.86), mark: .codex
        ),
    ]

    /// A fresh PATH probe each call (cheap: one `isExecutableFile` per
    /// candidate directory) rather than a cached snapshot, so a harness
    /// installed mid-session shows up the next time a pristine pane is
    /// created rather than only at process start.
    static func detected(pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [HarnessEntry] {
        let directories = pathEnvironment.split(separator: ":").map(String.init)
        return known.filter { entry in
            directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + entry.binary) }
        }
    }
}

/// Renders on a pristine flock-created pane: the bare shell prompt stays
/// visible above (this view never covers it -- it only occupies the space
/// below, via its own top spacer), one button per detected harness centered
/// in that space, and a dim hint at the very bottom. The buttons are the
/// only thing here that answers the pointer: the spacers draw nothing and so
/// claim nothing, and the hint opts itself out, which leaves every other
/// click reaching the terminal underneath (plain-click-to-focus, or
/// typing). `PaneLauncherOverlayTests` asserts both halves of that by
/// hit-testing the real view.
struct PaneLauncherOverlay: View {
    let theme: Theme
    let entries: [HarnessEntry]
    let onLaunch: (HarnessEntry) -> Void

    var body: some View {
        VStack(spacing: ChromeMetrics.Launcher.spacing) {
            Spacer(minLength: 0)
            HStack(spacing: ChromeMetrics.Launcher.buttonSpacing) {
                ForEach(entries) { entry in
                    Button { onLaunch(entry) } label: {
                        HStack(spacing: ChromeMetrics.Launcher.labelSpacing) {
                            HarnessBadge(entry: entry)
                            Text(entry.displayName)
                                .font(ChromeType.launcherName)
                                .foregroundStyle(theme.textStrong)
                        }
                        .padding(.horizontal, ChromeMetrics.Launcher.buttonHorizontalPadding)
                        .padding(.vertical, ChromeMetrics.Launcher.buttonVerticalPadding)
                        .background(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).fill(theme.tabRest))
                        .overlay(RoundedRectangle(cornerRadius: PaneChrome.cornerRadius).strokeBorder(theme.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flock.pane.launcher.\(entry.binary)")
                }
            }
            Spacer(minLength: 0)
            Text("detected on PATH · click launches in this pane · typing hides these")
                .font(ChromeType.launcherHint)
                .foregroundStyle(theme.textLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ChromeMetrics.Launcher.hintHorizontalPadding)
                .padding(.bottom, ChromeMetrics.Launcher.hintBottomPadding)
                // Hit testing is off per drawn element, never on the stack
                // around them: a disabled ancestor takes its whole subtree
                // out of hit testing, and a descendant cannot opt back in.
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, ChromeMetrics.Launcher.promptClearance)
    }
}

/// The vendor's mark where there is one, the monogram where there is not.
private struct HarnessBadge: View {
    let entry: HarnessEntry

    var body: some View {
        if let mark = entry.mark, mark.cgPath != nil {
            Circle()
                .fill(Color(mark.ground))
                .frame(width: ChromeMetrics.Launcher.monogram, height: ChromeMetrics.Launcher.monogram)
                .overlay(
                    MarkShape(mark: mark)
                        .fill(Color(mark.ink))
                        .padding(ChromeMetrics.Launcher.markInset)
                )
        } else {
            MonogramBadge(entry: entry)
        }
    }
}

/// Scales the mark to fit, centered, in whatever space it is given. The
/// decode happens here, per draw, rather than once into shared storage: a
/// `Shape` must be `Sendable`, so it cannot carry the decoded `CGPath`, and a
/// cache would be shared mutable state for a parse that costs microseconds.
private struct MarkShape: Shape {
    let mark: HarnessMark

    func path(in rect: CGRect) -> Path {
        guard let cgPath = mark.cgPath else { return Path() }
        // Fitted to the ink rather than to the document each mark was drawn
        // in: the two vendors leave very different margins inside their own
        // viewBox, so honoring those would render one mark at half the size
        // of the other. The badge's own inset gives every mark clear space.
        let ink = cgPath.boundingBoxOfPath
        guard ink.width > 0, ink.height > 0 else { return Path() }
        let scale = min(rect.width / ink.width, rect.height / ink.height)
        let size = CGSize(width: ink.width * scale, height: ink.height * scale)
        let transform = CGAffineTransform(
            translationX: rect.midX - size.width / 2, y: rect.midY - size.height / 2
        )
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -ink.minX, y: -ink.minY)
        return Path(cgPath).applying(transform)
    }
}

private struct MonogramBadge: View {
    let entry: HarnessEntry

    var body: some View {
        Circle()
            .fill(entry.monogramColor)
            .frame(width: ChromeMetrics.Launcher.monogram, height: ChromeMetrics.Launcher.monogram)
            .overlay(
                Text(entry.monogram)
                    .font(ChromeType.launcherMonogram)
                    .foregroundStyle(.white)
            )
    }
}
