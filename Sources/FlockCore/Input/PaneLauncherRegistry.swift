import Foundation

/// Decides, per pane, whether the harness launcher is offered right now.
///
/// The answer is a function of the pane's present state, never its history:
/// the screen holds nothing but a prompt, nothing has been typed since it
/// last emptied, and herdr says the shell holds the foreground. Each signal
/// arrives through its own `record` method with its own timestamp, so this
/// type reads no clock and tests never sleep.
@MainActor
public final class PaneLauncherRegistry {
    /// How long a prompt has to finish painting after the pane first paints,
    /// after the screen drops to bare, or after a navigator ends. A prompt
    /// can land in two frames, and a shell prints warnings on its way up;
    /// erring long only lets a quick command's output in, and a keystroke
    /// closes the window before that output can arrive.
    public static let learningWindow: TimeInterval = 2

    /// The most rows a first screen may hold and still be taken for a bare
    /// prompt when the pane's own prompt height is unknown: a two-line prompt
    /// plus two startup warnings. A two-line prompt, one line of output and
    /// a new prompt is five.
    public static let unknownHeightCap = 4

    /// No prompt is taller than this. A report above it inside a learning
    /// window is output and closes the window instead of teaching.
    public static let tallestPrompt = 8

    /// How long after a navigator command is typed an idle pane still means
    /// the command has yet to start. Past it, idle means it already finished.
    public static let navigationStartCeiling: TimeInterval = 3

    /// Delays between asks of herdr while the shell is busy at a bare screen.
    /// The last one repeats; a screen change starts over.
    public static let defaultPollBackoff: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
    ]

    private enum Foreground {
        case unasked, idle, notIdle
    }

    private struct Navigation {
        let startedAt: Date
        var seenRunning = false
    }

    private struct Pane {
        var promptRows: Int?
        var rows: Int?
        var typed = false
        var starting = false
        var learningUntil: Date?
        var foreground: Foreground = .unasked
        var failedAsks = 0
        var navigation: Navigation?

        var isBare: Bool {
            guard let rows, let promptRows else { return false }
            return rows <= promptRows
        }
    }

    private let pollBackoff: [Duration]
    private var panes: [PaneID: Pane] = [:]

    public init(pollBackoff: [Duration] = PaneLauncherRegistry.defaultPollBackoff) {
        precondition(!pollBackoff.isEmpty)
        self.pollBackoff = pollBackoff
    }

    /// The surface's count of non-empty rows on its ACTIVE screen, not its
    /// scrollback: a clear empties the screen and keeps the history, so a
    /// scrollback-wide count could never come back down. A repeat of the
    /// last count is a repaint and changes nothing.
    public func recordRows(_ pane: PaneID, rows: Int, at time: Date) {
        var state = panes[pane] ?? Pane()
        let previous = state.rows
        guard rows != previous else { return }
        state.rows = rows
        state.foreground = .unasked
        state.failedAsks = 0
        defer { panes[pane] = state }
        if state.navigation != nil { return }
        if state.starting {
            state.promptRows = rows
            return
        }
        if let until = state.learningUntil, time < until {
            if rows <= Self.tallestPrompt {
                state.promptRows = rows
            } else {
                state.learningUntil = nil
            }
            return
        }
        state.learningUntil = nil
        guard let previous else {
            if rows <= Self.unknownHeightCap {
                state.promptRows = rows
                state.learningUntil = time.addingTimeInterval(Self.learningWindow)
            }
            return
        }
        let bareHeight = state.promptRows ?? Self.unknownHeightCap
        if rows < previous, rows <= bareHeight {
            state.typed = false
            state.promptRows = rows
            state.learningUntil = time.addingTimeInterval(Self.learningWindow)
        }
    }

    /// A real keystroke into the pane. Keys typed while a navigator runs are
    /// the picker's, not the pane's.
    public func recordKeystroke(_ pane: PaneID) {
        var state = panes[pane] ?? Pane()
        guard state.navigation == nil else { return }
        state.typed = true
        state.starting = false
        state.learningUntil = nil
        panes[pane] = state
    }

    /// A pane flock itself just created. Until herdr first answers idle or a
    /// key is typed, every rows report is the prompt's height, uncapped: the
    /// shell may print a banner of any size on its way up. A pane first seen
    /// mid-life is never marked, so it keeps the unknown-height cap.
    public func recordCreated(_ pane: PaneID) {
        var state = panes[pane] ?? Pane()
        state.starting = true
        panes[pane] = state
    }

    /// The key that asks the shell to clear: an explicit ask for a fresh
    /// screen, so whatever was typed before it no longer counts, and herdr
    /// is asked again.
    public func recordClearKey(_ pane: PaneID) {
        var state = panes[pane] ?? Pane()
        guard state.navigation == nil else { return }
        state.typed = false
        state.foreground = .unasked
        state.failedAsks = 0
        panes[pane] = state
    }

    /// `idle` is whether the shell alone holds the pane's foreground; nil
    /// when herdr could not say. While a navigator runs this drives its end:
    /// idle once the command was seen running, or idle past the start
    /// ceiling. Otherwise it answers the question `nextPollDelay` asked.
    public func recordForegroundJob(_ pane: PaneID, idle: Bool?, at time: Date) {
        var state = panes[pane] ?? Pane()
        defer { panes[pane] = state }
        if var navigation = state.navigation {
            guard let idle else { return }
            if !idle {
                navigation.seenRunning = true
                state.navigation = navigation
                return
            }
            guard navigation.seenRunning
                || time.timeIntervalSince(navigation.startedAt) >= Self.navigationStartCeiling
            else { return }
            state.navigation = nil
            state.typed = false
            state.learningUntil = time.addingTimeInterval(Self.learningWindow)
            state.foreground = .unasked
            state.failedAsks = 0
            return
        }
        if idle == true {
            state.starting = false
            state.foreground = .idle
            state.failedAsks = 0
        } else {
            state.foreground = .notIdle
            state.failedAsks += 1
        }
    }

    /// A navigator command (a directory picker) was just typed into this
    /// pane. The launcher steps aside until the shell is back at a prompt.
    public func recordNavigationStarted(_ pane: PaneID, at time: Date) {
        var state = panes[pane] ?? Pane()
        state.navigation = Navigation(startedAt: time)
        state.typed = true
        state.learningUntil = nil
        panes[pane] = state
    }

    public func isNavigating(_ pane: PaneID) -> Bool {
        panes[pane]?.navigation != nil
    }

    /// The pane is gone from herdr; nothing about it is worth keeping.
    public func forget(_ pane: PaneID) {
        panes[pane] = nil
    }

    public func isShowing(_ pane: PaneID) -> Bool {
        guard let state = panes[pane], isCandidate(state) else { return false }
        return state.foreground == .idle
    }

    /// nil when the pane is not a candidate (not bare, typed into, under a
    /// navigator, or already answered idle); `.zero` when herdr has not been
    /// asked since the screen last changed; otherwise the wait before asking
    /// again.
    public func nextPollDelay(_ pane: PaneID) -> Duration? {
        guard let state = panes[pane], isCandidate(state) else { return nil }
        switch state.foreground {
        case .idle: return nil
        case .unasked: return .zero
        case .notIdle: return pollBackoff[min(state.failedAsks, pollBackoff.count) - 1]
        }
    }

    /// The rows the pane's screen holds, which the overlay keeps clear of.
    public func occupiedRows(_ pane: PaneID) -> Int {
        panes[pane]?.rows ?? 0
    }

    private func isCandidate(_ state: Pane) -> Bool {
        state.navigation == nil && !state.typed && state.isBare
    }
}
