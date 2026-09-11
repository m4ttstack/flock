import SwiftUI

/// One CLI agent harness `HarnessRoster` knows how to launch. `monogramColor`
/// stands in for the official brand mark until one is bundled (see
/// `Resources/HarnessMarks/README.md`: neither vendor's official site
/// yielded a fetchable mark non-interactively, so both render as a
/// monogram today).
struct HarnessEntry: Identifiable, Equatable {
    let id: String
    let binary: String
    let displayName: String
    let monogram: String
    let monogramColor: Color
}

/// Every harness paddock knows how to offer, resolved against PATH at
/// launcher-render time. Extend `known` to add one; PATH resolution alone
/// decides what actually renders for a given machine.
enum HarnessRoster {
    static let known: [HarnessEntry] = [
        HarnessEntry(id: "claude", binary: "claude", displayName: "claude", monogram: "C", monogramColor: .init(red: 0.82, green: 0.51, blue: 0.31)),
        HarnessEntry(id: "codex", binary: "codex", displayName: "codex", monogram: "X", monogramColor: .init(red: 0.29, green: 0.56, blue: 0.86)),
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

/// Renders on a pristine paddock-created pane: the bare shell prompt stays
/// visible above (this view never covers it -- it only occupies the space
/// below, via its own top spacer), one button per detected harness centered
/// in that space, and a dim hint at the very bottom. Everywhere except the
/// button row is `allowsHitTesting(false)`, so a click anywhere else still
/// reaches the terminal underneath (plain-click-to-focus, or eventually
/// typing) rather than being swallowed by the overlay.
struct PaneLauncherOverlay: View {
    let theme: Theme
    let entries: [HarnessEntry]
    let onLaunch: (HarnessEntry) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                ForEach(entries) { entry in
                    Button { onLaunch(entry) } label: {
                        HStack(spacing: 8) {
                            MonogramBadge(entry: entry)
                            Text(entry.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.text)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.paneHeaderBg))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paddock.pane.launcher.\(entry.binary)")
                }
            }
            .allowsHitTesting(true)
            Spacer(minLength: 0)
            Text("detected on PATH · click launches in this pane · typing hides these")
                .font(.system(size: 9))
                .foregroundStyle(theme.overlay0)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 28) // leaves the header-adjacent prompt row unobscured
        .allowsHitTesting(false)
    }
}

private struct MonogramBadge: View {
    let entry: HarnessEntry

    var body: some View {
        Circle()
            .fill(entry.monogramColor)
            .frame(width: 22, height: 22)
            .overlay(
                Text(entry.monogram)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
