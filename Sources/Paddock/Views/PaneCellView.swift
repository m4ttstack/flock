import PaddockCore
import SwiftUI

/// A single pane cell in status-card mode: title/label, cwd tail, agent dot,
/// and a lazily fetched last line. Live terminal rendering is Task 17-18;
/// this task never attaches a PTY stream.
struct PaneCellView: View {
    let theme: Theme
    let pane: PaneRecord
    let isFocused: Bool
    let lastLine: String?

    /// The terminal's own ground, held constant across every theme per the
    /// task brief, until live content (Task 17-18) replaces this placeholder.
    private static let terminalGround = Color(red: 0x19 / 255, green: 0x1A / 255, blue: 0x22 / 255)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Self.terminalGround)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isFocused ? theme.accent : theme.separator, lineWidth: isFocused ? 2 : 1)
        )
        // A solid, unblurred halo ring outside the cell (matching the
        // reference's `box-shadow: 0 0 0 3px`, zero blur, fixed spread).
        // `HaloRing` is a real ring geometry (even-odd cutout), not a filled
        // rect relying on the opaque cell to hide its interior -- a filled
        // rect there visibly bled accent color across the header.
        .background {
            if isFocused {
                HaloRing(cornerRadius: 9, thickness: 3)
                    .fill(theme.accent.opacity(0.18), style: FillStyle(eoFill: true))
                    .padding(-3)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(status: pane.agentStatus, theme: theme)
            Text(pane.terminalTitleStripped ?? pane.label ?? "shell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let statusColor {
                Text(pane.agentStatus.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(statusColor.opacity(0.14)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.paneHeaderBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    /// Status chips only accompany the active states (working/blocked/done);
    /// idle and unknown are dot-only per the pane-states reference.
    private var statusColor: Color? {
        switch pane.agentStatus {
        case .working: theme.yellow
        case .blocked: theme.red
        case .done: theme.teal
        case .idle, .unknown: nil
        }
    }

    /// Vertical anatomy per the reference (glyph, cwd, chip when present,
    /// hint), centered -- both explicitly, so a reader doesn't have to know
    /// that `.frame(maxWidth: .infinity)`'s default alignment happens to
    /// agree with what's wanted here.
    private var content: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(theme.overlay0)
            Text(cwdTail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.subtext0)
            if let lastLine, !lastLine.isEmpty {
                Text(lastLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.overlay0)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Self.terminalGround)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.separator, lineWidth: 1))
                    )
            }
            Text(hintText)
                .font(.system(size: 9))
                .foregroundStyle(theme.overlay0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(14)
    }

    /// Task 16's click jumps herdr focus; Task 17-18 attaches a live PTY
    /// stream on click instead, and the hint changes to match.
    private var hintText: String { "click to focus in herdr" }

    private var cwdTail: String {
        guard let last = pane.cwd.split(separator: "/").last else { return pane.cwd }
        return "~/\(last)"
    }
}

/// A ring shape (outer rounded rect minus an inset inner one, even-odd
/// filled) so the focused-pane halo is geometrically confined to its band --
/// no reliance on an opaque foreground to hide fill in the interior.
private struct HaloRing: Shape {
    var cornerRadius: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius + thickness)
        path.addPath(Path(roundedRect: rect.insetBy(dx: thickness, dy: thickness), cornerRadius: cornerRadius))
        return path
    }
}
