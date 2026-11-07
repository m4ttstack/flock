import Foundation

private func clamp(_ value: Double) -> Double { SwitchLoaderEasing.clamp(value) }
private func easeOut(_ t: Double) -> Double { SwitchLoaderEasing.easeOut(t) }
private func easeInOut(_ t: Double) -> Double { SwitchLoaderEasing.easeInOut(t) }

/// One showing of the switch loader as a pure function of time, so a frame
/// can be drawn at any instant and a view rebuilt mid-run draws the same one.
/// Times are seconds since the run started.
public struct SwitchLoaderRun: Equatable, Sendable {
    public enum Timing {
        public static let breath = PaneLoaderChoreography.loopDuration
        /// Held at full spread between breaths, so the loop reads as calm
        /// breathing rather than a pulse.
        public static let rest: Double = 0.4
        public static let period = breath + rest
        public static let crossfade: Double = 0.35
        public static let appear: Double = 0.2
        public static let fadeOut: Double = 0.25
        public static let warnTint: Double = 0.4
        public static let revealDelay: Double = 0.25
        public static let reveal: Double = 0.4
        public static let glowSettle: Double = 0.6
        public static let shimmerPeriod: Double = 1.6
        public static let reducedPulsePeriod: Double = 2.4
    }

    /// One slot of copy: the line it shows and the one it is fading from.
    public struct Line: Equatable, Sendable {
        public private(set) var previous: String?
        public private(set) var current: String
        public private(set) var changedAt: Double

        public init(_ text: String) {
            current = text
            changedAt = 0
        }

        mutating func set(_ text: String, at time: Double) {
            guard text != current else { return }
            previous = current
            current = text
            changedAt = time
        }

        /// 0 shows only `previous`, 1 only `current`.
        public func mix(at time: Double) -> Double {
            previous == nil ? 1 : easeInOut(clamp((time - changedAt) / Timing.crossfade))
        }
    }

    public let id: Int
    /// Absolute seconds, on the clock the presenter and the view share.
    public let startedAt: Double
    public private(set) var title: Line
    public private(set) var status: Line
    public private(set) var phase: SwitchLoaderPhase
    public private(set) var showsSwitchToDefault: Bool
    /// Where the current run of breaths began; a recovery restarts them.
    public private(set) var breathingSince: Double = 0
    /// Where the breaths hold, at full spread: the rest after a failure or
    /// before the fade.
    public private(set) var breathStop: Double?
    public private(set) var failedAt: Double?
    public private(set) var recoveredAt: Double?
    /// When the fade out starts.
    public private(set) var finishAt: Double?

    public init(id: Int, startedAt: Double, model: SwitchLoaderModel) {
        self.id = id
        self.startedAt = startedAt
        title = Line(model.title)
        status = Line(model.status)
        phase = .working
        showsSwitchToDefault = model.showsSwitchToDefault
        apply(model, at: 0)
    }

    public var isFinishing: Bool { finishAt != nil }

    /// When the fade has finished and the run can be dropped.
    public var endsAt: Double? { finishAt.map { $0 + Timing.fadeOut } }

    /// When nothing on screen moves any more: a failure once its tint, glow
    /// and button have settled. Nil while anything still animates.
    public var settlesAt: Double? {
        guard phase == .failed, let failedAt, let breathStop else { return nil }
        return max(breathStop + Timing.glowSettle, failedAt + Timing.revealDelay + Timing.reveal, failedAt + Timing.warnTint,
                   status.changedAt + Timing.crossfade, title.changedAt + Timing.crossfade)
    }

    /// Takes the model's copy and phase at `time`. A finishing run keeps the
    /// copy it is fading out with.
    public mutating func apply(_ model: SwitchLoaderModel, at time: Double) {
        guard finishAt == nil else { return }
        title.set(model.title, at: time)
        status.set(model.status, at: time)
        showsSwitchToDefault = model.showsSwitchToDefault
        switch (phase, model.phase) {
        case (.working, .failed):
            phase = .failed
            failedAt = time
            recoveredAt = nil
            breathStop = time <= breathingSince ? time : Self.restPoint(atOrAfter: time - breathingSince) + breathingSince
        case (.failed, .working), (.failed, .done):
            phase = .working
            recoveredAt = time
            failedAt = nil
            if let breathStop, time >= breathStop { breathingSince = time }
            breathStop = nil
        default:
            break
        }
        if model.phase == .done { finish(at: time, waitForBreath: true) }
    }

    /// Starts the fade: at the end of the breath in progress and never
    /// before one whole breath, or at `time` itself.
    public mutating func finish(at time: Double, waitForBreath: Bool) {
        guard finishAt == nil else { return }
        phase = .done
        let start = waitForBreath
            ? max(Self.restPoint(atOrAfter: time - breathingSince) + breathingSince, Timing.breath)
            : time
        finishAt = start
        breathStop = min(breathStop ?? start, start)
    }

    public func frame(at time: Double) -> SwitchLoaderFrame {
        let breathTime = min(time, breathStop ?? .infinity)
        let breath = Self.breathClock(max(breathTime - breathingSince, 0))

        var glow = 1.0
        var warn = 0.0
        var reveal = 0.0
        if let failedAt {
            let settle = breathStop ?? failedAt
            glow = 1 - easeInOut(clamp((time - failedAt) / max(settle - failedAt + Timing.glowSettle, 0.01)))
            warn = easeInOut(clamp((time - failedAt) / Timing.warnTint))
            reveal = showsSwitchToDefault ? easeInOut(clamp((time - failedAt - Timing.revealDelay) / Timing.reveal)) : 0
        } else if let recoveredAt {
            glow = easeInOut(clamp((time - recoveredAt) / Timing.glowSettle))
            warn = 1 - easeInOut(clamp((time - recoveredAt) / Timing.warnTint))
        }

        let appear = easeOut(clamp(time / Timing.appear))
        let fade = finishAt.map { easeInOut(clamp((time - $0) / Timing.fadeOut)) } ?? 0
        let shimmerPhase = max(time, 0).truncatingRemainder(dividingBy: Timing.shimmerPeriod) / Timing.shimmerPeriod

        return SwitchLoaderFrame(
            runTime: time,
            title: .init(previous: title.previous, current: title.current, mix: title.mix(at: time)),
            status: .init(previous: status.previous, current: status.current, mix: status.mix(at: time)),
            breath: breath,
            glow: glow,
            shimmerOpacity: 1 - warn,
            shimmerPosition: easeInOut(shimmerPhase),
            warn: warn,
            failReveal: reveal,
            screenOpacity: appear * (1 - fade),
            exit: fade,
            isFailed: phase == .failed
        )
    }

    /// Run time to choreography time: each period plays one breath, then
    /// holds its end, where the echoes are fully spread.
    public static func breathClock(_ time: Double) -> Double {
        let cycles = (time / Timing.period).rounded(.down)
        return cycles * Timing.breath + min(time - cycles * Timing.period, Timing.breath)
    }

    /// The first instant at or after `time` that sits at full spread: the
    /// end of the breath in progress, or `time` itself during a rest.
    public static func restPoint(atOrAfter time: Double) -> Double {
        let cycles = (time / Timing.period).rounded(.down)
        let local = time - cycles * Timing.period
        return local < Timing.breath ? cycles * Timing.period + Timing.breath : time
    }
}

/// One drawable instant of a `SwitchLoaderRun`.
public struct SwitchLoaderFrame: Equatable, Sendable {
    /// A line of copy mid-crossfade: `mix` 0 shows only `previous`, 1 only
    /// `current`.
    public struct Crossfade: Equatable, Sendable {
        public let previous: String?
        public let current: String
        public let mix: Double

        public init(previous: String?, current: String, mix: Double) {
            self.previous = previous
            self.current = current
            self.mix = mix
        }
    }

    public let runTime: Double
    public let title: Crossfade
    public let status: Crossfade
    /// The clock the ram's echoes read: it advances only while a breath
    /// runs, and holds through each rest and once stopped.
    public let breath: Double
    public let glow: Double
    public let shimmerOpacity: Double
    /// Where the highlight sits along the track, 0 to 1, already eased.
    public let shimmerPosition: Double
    public let warn: Double
    public let failReveal: Double
    public let screenOpacity: Double
    /// 0 until the fade out starts, 1 once it is gone.
    public let exit: Double
    public let isFailed: Bool

    public func merge(delay: Double) -> Double {
        PaneLoaderChoreography.mergeProgress(elapsed: breath, startDelay: delay)
    }

    public var meanMerge: Double {
        let echoes = HerdrRamTrail.echoes
        return echoes.map { merge(delay: $0.startDelay) }.reduce(0, +) / Double(echoes.count)
    }
}

public enum SwitchLoaderEasing {
    public static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    public static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    public static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
