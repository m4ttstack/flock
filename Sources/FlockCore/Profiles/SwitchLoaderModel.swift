import Foundation

public enum SwitchLoaderPhase: Equatable, Sendable {
    case working
    case failed
    /// Panes are being served; the loader finishes its breath and fades.
    case done
}

/// Everything the switch loader's copy depends on. `tunnel` is read only for
/// a machine.
public struct SwitchLoaderInput: Equatable, Sendable {
    public var label: String
    public var isMachine: Bool
    public var isDefaultProfile: Bool
    public var tunnel: MachineTunnelState
    public var store: ConnectionState
    public var tunnelUpGraceActive: Bool
    public var currentMachineMissing: Bool
    /// A switch to this profile is underway and its store has not been live yet.
    public var isSwitching: Bool

    public init(
        label: String, isMachine: Bool, isDefaultProfile: Bool, tunnel: MachineTunnelState = .stopped,
        store: ConnectionState, tunnelUpGraceActive: Bool = false, currentMachineMissing: Bool = false,
        isSwitching: Bool = false
    ) {
        self.label = label
        self.isMachine = isMachine
        self.isDefaultProfile = isDefaultProfile
        self.tunnel = tunnel
        self.store = store
        self.tunnelUpGraceActive = tunnelUpGraceActive
        self.currentMachineMissing = currentMachineMissing
        self.isSwitching = isSwitching
    }
}

/// What the switch loader says. The tunnel outranks the store until the
/// forward is up, as in `MachineConnectionCopy`; a removed machine outranks both.
public struct SwitchLoaderModel: Equatable, Sendable {
    public let phase: SwitchLoaderPhase
    public let title: String
    public let status: String
    public let showsSwitchToDefault: Bool

    public init(phase: SwitchLoaderPhase, title: String, status: String, showsSwitchToDefault: Bool) {
        self.phase = phase
        self.title = title
        self.status = status
        self.showsSwitchToDefault = showsSwitchToDefault
    }

    public static let attaching = "Attaching"

    /// Nil where the loader has nothing to say: a local profile that is not
    /// switching, or whose server is not running, which `NoHerdrScreen` owns.
    public static func make(_ input: SwitchLoaderInput) -> SwitchLoaderModel? {
        let label = input.label
        func working(_ status: String) -> SwitchLoaderModel {
            SwitchLoaderModel(phase: .working, title: switching(label), status: status, showsSwitchToDefault: false)
        }
        func failed(_ title: String, _ status: String) -> SwitchLoaderModel {
            SwitchLoaderModel(phase: .failed, title: title, status: status, showsSwitchToDefault: !input.isDefaultProfile)
        }
        let done = SwitchLoaderModel(phase: .done, title: switching(label), status: attaching, showsSwitchToDefault: false)
        let notRunning = failed("herdr isn't running on \(label).", "Start herdr on \(label) and Flock will attach.")

        guard input.isMachine else {
            guard input.isSwitching else { return nil }
            switch input.store {
            case .live, .unsupported: return done
            case .connecting, .reconnecting: return working(attaching)
            case .notRunning: return nil
            }
        }
        if input.store == .live { return done }
        if input.currentMachineMissing {
            return failed(MachineConnectionCopy.removed(label: label), "Pick another profile, or switch to Default.")
        }
        switch input.tunnel {
        case .stopped, .connecting:
            return working("Connecting to \(label)\u{2026}")
        case .unreachable:
            let banner = MachineConnectionCopy.banner(label: label, tunnel: input.tunnel, store: input.store) ?? ""
            return failed(MachineConnectionCopy.short(banner), MachineConnectionCopy.detail(banner))
        case .noServer:
            return notRunning
        case .up:
            switch input.store {
            case .live, .unsupported: return done
            case .connecting: return working(attaching)
            case .reconnecting, .notRunning: return input.tunnelUpGraceActive ? working(attaching) : notRunning
            }
        }
    }

    public static func switching(_ label: String) -> String { "Switching to \(label)" }
}
