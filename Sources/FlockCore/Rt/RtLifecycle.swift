import Foundation

/// One rt command's life in its hidden tab, told by polls: whether anything
/// but the shell holds a foreground, and what the status and result files
/// hold. Pure, so every rule below is pinned by a test without a herdr.
///
/// `run` has two phases so the picker's end and the script's start are never
/// confused: the moment between rt exiting and the script starting reads as
/// idle, and nothing but the phase says which it is.
public struct RtLifecycle: Equatable, Sendable {
    /// How long an idle pane still means the command has yet to start. Past
    /// it, a command never seen running has already finished.
    public static let startCeiling: TimeInterval = 3

    public enum Stage: Equatable, Sendable {
        case running, picking, script, selfLaunched, done
    }

    public struct Observation: Equatable, Sendable {
        public var firstPaneBusy: Bool
        public var anyPaneBusy: Bool
        public var statusExists: Bool
        public var status: Int32?
        public var out: String?
        public var now: Date

        public init(firstPaneBusy: Bool, anyPaneBusy: Bool, statusExists: Bool, status: Int32?, out: String?, now: Date) {
            self.firstPaneBusy = firstPaneBusy
            self.anyPaneBusy = anyPaneBusy
            self.statusExists = statusExists
            self.status = status
            self.out = out
            self.now = now
        }
    }

    public enum Outcome: Equatable, Sendable {
        case watching
        case typePhaseTwo(RunResolveResult)
        case closeTab
        case cdLinkedPane(String)
        case exited(Int32?)
        case finished(Int32?)
        case runnerEnded
    }

    public let kind: RtKind
    public private(set) var stage: Stage
    private var startedAt: Date
    private var seenBusy = false
    private var idleSince: Date?

    public init(kind: RtKind, startedAt: Date) {
        self.kind = kind
        self.stage = kind == .run ? .picking : .running
        self.startedAt = startedAt
    }

    public static func resumed(kind: RtKind, stage: Stage, at time: Date) -> RtLifecycle {
        var lifecycle = RtLifecycle(kind: kind, startedAt: time)
        lifecycle.stage = stage
        return lifecycle
    }

    public mutating func phaseTwoTyped(at time: Date) {
        stage = .script
        startedAt = time
        seenBusy = false
        idleSince = nil
    }

    public mutating func observe(_ seen: Observation) -> Outcome {
        if seen.anyPaneBusy {
            seenBusy = true
            idleSince = nil
        }
        switch stage {
        case .done:
            return .watching
        case .running:
            guard !seen.anyPaneBusy else { return .watching }
            if ended(seen) {
                stage = .done
                return singlePhaseOutcome(seen)
            }
            guard stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .exited(nil)
        case .picking:
            return pickingOutcome(seen)
        case .script:
            guard !seen.anyPaneBusy else { return .watching }
            guard ended(seen) || stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .finished(seen.statusExists ? seen.status : nil)
        case .selfLaunched:
            guard !seen.anyPaneBusy, seenBusy || pastCeiling(seen) else { return .watching }
            stage = .done
            return .finished(nil)
        }
    }

    private mutating func pickingOutcome(_ seen: Observation) -> Outcome {
        guard !seen.firstPaneBusy else { return .watching }
        guard seen.statusExists else {
            if !seenBusy, pastCeiling(seen) {
                stage = .done
                return .exited(nil)
            }
            guard stoppedWithoutStatus(seen) else { return .watching }
            stage = .done
            return .closeTab
        }
        if let result = RtFileParse.runResult(seen.out) {
            return .typePhaseTwo(result)
        }
        if seen.status == 0 {
            stage = .selfLaunched
            startedAt = seen.now
            seenBusy = false
            return .watching
        }
        stage = .done
        return .closeTab
    }

    private func ended(_ seen: Observation) -> Bool {
        seen.statusExists || (!seenBusy && pastCeiling(seen))
    }

    /// A job killed by a signal (ctrl+c on a dev server) makes zsh and bash
    /// skip the rest of its `;` list, so the status is never written. Idle
    /// this long after running, with no status, means it ended that way.
    private mutating func stoppedWithoutStatus(_ seen: Observation) -> Bool {
        guard seenBusy else { return false }
        let since = idleSince ?? seen.now
        idleSince = since
        return seen.now.timeIntervalSince(since) >= Self.startCeiling
    }

    private func pastCeiling(_ seen: Observation) -> Bool {
        seen.now.timeIntervalSince(startedAt) >= Self.startCeiling
    }

    private func singlePhaseOutcome(_ seen: Observation) -> Outcome {
        guard seen.statusExists, seen.status == 0 || seen.status == 130 else {
            return .exited(seen.statusExists ? seen.status : nil)
        }
        switch kind {
        case .nav:
            let path = seen.out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? .closeTab : .cdLinkedPane(path)
        case .glitter, .run:
            return .closeTab
        case .runner:
            return .runnerEnded
        }
    }
}
