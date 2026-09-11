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
        .shadow(color: isFocused ? theme.accent.opacity(0.18) : .clear, radius: isFocused ? 6 : 0)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(status: pane.agentStatus, theme: theme)
            Text(pane.terminalTitleStripped ?? pane.label ?? "shell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.paneHeaderBg)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
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
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface0))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    }

    private var cwdTail: String {
        guard let last = pane.cwd.split(separator: "/").last else { return pane.cwd }
        return "~/\(last)"
    }
}
