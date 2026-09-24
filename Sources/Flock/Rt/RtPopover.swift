import FlockCore
import SwiftUI

/// What the legend's rt button opens: rt's commands for the pane's folder,
/// then the pane's rt run items in the order they were opened. Drawn in the
/// chat popover's language.
struct RtPopover: View {
    let theme: Theme
    let folder: String
    let commands: [RtCommandRow]
    let runs: [RtRunRow]
    let onCommand: (RtKind) -> Void
    let onRun: (String) -> Void

    @State private var hoveredCommand: RtKind?

    private typealias Metrics = ChromeMetrics.RtPopover

    /// `previewHoveredCommand` is for render tests only: the row drawn as
    /// hovered without a pointer.
    init(
        theme: Theme, folder: String, commands: [RtCommandRow], runs: [RtRunRow],
        onCommand: @escaping (RtKind) -> Void, onRun: @escaping (String) -> Void,
        previewHoveredCommand: RtKind? = nil
    ) {
        self.theme = theme
        self.folder = folder
        self.commands = commands
        self.runs = runs
        self.onCommand = onCommand
        self.onRun = onRun
        self._hoveredCommand = State(initialValue: previewHoveredCommand)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            commandBand
            if !runs.isEmpty {
                runsLabel
                runBand
            }
        }
        .frame(width: Metrics.width)
        .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(Color(theme.palette.panelBg)))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(Color(theme.palette.surface1), lineWidth: ChromeMetrics.ruleWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .background(PopoverAppearancePin(isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)))
    }

    private var header: some View {
        HStack(spacing: 0) {
            RtBadge(size: Metrics.Header.badgeSize, font: ChromeType.rtPopoverBadge)
            Spacer(minLength: Metrics.Header.gap)
            folderChip
        }
        .padding(.horizontal, Metrics.Header.horizontalPadding)
        .frame(width: Metrics.width, height: Metrics.Header.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(theme.palette.surface0)).frame(height: ChromeMetrics.ruleWidth)
        }
    }

    private var folderChip: some View {
        HStack(spacing: Metrics.Header.chipGap) {
            Image(systemName: "folder")
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.overlay0)
                .frame(width: Metrics.Header.chipGlyphSize, height: Metrics.Header.chipGlyphSize)
            Text(folder)
                .font(ChromeType.rtPopoverFolder)
                .foregroundStyle(theme.subtext0)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Metrics.Header.chipHorizontalPadding)
        .frame(height: Metrics.Header.chipHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.Header.chipCornerRadius).fill(Color(theme.palette.surface0)))
    }

    private var commandBand: some View {
        VStack(spacing: 0) {
            ForEach(commands) { command in
                commandRow(command)
            }
        }
        .padding(.vertical, Metrics.Commands.verticalPadding)
        .padding(.horizontal, Metrics.Commands.horizontalPadding)
    }

    private func commandRow(_ command: RtCommandRow) -> some View {
        let isHovered = hoveredCommand == command.kind
        return Button(action: { onCommand(command.kind) }) {
            HStack(spacing: Metrics.Row.gap) {
                Image(systemName: Self.symbolName(command.kind))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isHovered ? theme.accent : theme.overlay0)
                    .frame(width: Metrics.Row.glyphSize, height: Metrics.Row.glyphSize)
                Text(command.title)
                    .font(ChromeType.rtPopoverRow)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(command.hint)
                    .font(ChromeType.rtPopoverHint)
                    .foregroundStyle(theme.overlay0)
                    .lineLimit(1)
            }
            .padding(.horizontal, Metrics.Row.horizontalPadding)
            .frame(height: Metrics.Row.height)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Row.cornerRadius)
                    .fill(isHovered ? Color(theme.palette.selectionBg) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredCommand = command.kind
            } else if hoveredCommand == command.kind {
                hoveredCommand = nil
            }
        }
    }

    private var runsLabel: some View {
        Text("RUNS")
            .font(ChromeType.rtPopoverLabel)
            .tracking(ChromeType.rtPopoverLabelTracking)
            .foregroundStyle(theme.overlay0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Metrics.RunsLabel.topPadding)
            .padding(.trailing, Metrics.RunsLabel.trailingPadding)
            .padding(.bottom, Metrics.RunsLabel.bottomPadding)
            .padding(.leading, Metrics.RunsLabel.leadingPadding)
            .frame(width: Metrics.width, height: Metrics.RunsLabel.height, alignment: .top)
    }

    private var runBand: some View {
        VStack(spacing: 0) {
            ForEach(runs) { run in
                runRow(run)
            }
        }
        .padding(.horizontal, Metrics.Runs.horizontalPadding)
        .padding(.bottom, Metrics.Runs.bottomPadding)
    }

    private func runRow(_ run: RtRunRow) -> some View {
        Button(action: { onRun(run.id) }) {
            HStack(spacing: Metrics.Row.gap) {
                Circle()
                    .fill(dotColor(run.tone))
                    .frame(width: Metrics.Row.dotSize, height: Metrics.Row.dotSize)
                Text(run.title)
                    .font(ChromeType.rtPopoverRow)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(run.state)
                    .font(ChromeType.rtPopoverState)
                    .foregroundStyle(theme.subtext0)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, Metrics.Row.horizontalPadding)
            .frame(height: Metrics.Row.height)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Row.cornerRadius)
                    .fill(run.tone == .running ? Color(theme.palette.activeRowBg) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ tone: RtRunRow.Tone) -> Color {
        switch tone {
        case .running: theme.green
        case .exited: theme.red
        case .finished: theme.overlay0
        }
    }

    private static func symbolName(_ kind: RtKind) -> String {
        switch kind {
        case .nav: "folder"
        case .glitter: "arrow.triangle.branch"
        case .run: "play"
        case .runner: "waveform.path.ecg"
        }
    }
}
