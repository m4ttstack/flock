import Foundation
import Observation

@MainActor
public protocol ProfileSession: AnyObject {
    func start() async
    func shutdown() async
}

public struct ProfileSessionContext {
    public let profile: FlockProfile
    public let socketPath: String
    public let preferences: UserDefaults
    public let idState: UserDefaults
    /// False for a machine profile under a socket override, which then runs
    /// as a plain socket session.
    public let isRemoteMachine: Bool

    public init(
        profile: FlockProfile,
        socketPath: String,
        preferences: UserDefaults,
        idState: UserDefaults,
        isRemoteMachine: Bool = false
    ) {
        self.profile = profile
        self.socketPath = socketPath
        self.preferences = preferences
        self.idState = idState
        self.isRemoteMachine = isRemoteMachine
    }
}

public struct ProfileSessionEnvironment<Session: ProfileSession> {
    public var bundleID: String
    public var defaultSocketPath: String
    public var home: String
    /// `HERDR_SOCKET_PATH` from flock's own environment, when set.
    public var socketOverride: String?
    /// A nil suite name means `UserDefaults.standard`.
    public var defaults: @MainActor (_ suiteName: String?) -> UserDefaults
    /// false cancels the switch before anything is torn down or saved.
    public var confirmAttach: @MainActor (_ attachKey: String, _ targetLabel: String, _ stayLabel: String) async -> Bool
    public var register: @MainActor (_ attachKey: String) -> Void
    /// nil clears it: a machine profile's children must not inherit a local socket.
    public var setChildSocket: (_ socketPath: String?) -> Void
    public var make: @MainActor (ProfileSessionContext) -> Session

    public init(
        bundleID: String,
        defaultSocketPath: String,
        home: String,
        socketOverride: String?,
        defaults: @escaping @MainActor (_ suiteName: String?) -> UserDefaults,
        confirmAttach: @escaping @MainActor (_ attachKey: String, _ targetLabel: String, _ stayLabel: String) async -> Bool,
        register: @escaping @MainActor (_ attachKey: String) -> Void,
        setChildSocket: @escaping (_ socketPath: String?) -> Void,
        make: @escaping @MainActor (ProfileSessionContext) -> Session
    ) {
        self.bundleID = bundleID
        self.defaultSocketPath = defaultSocketPath
        self.home = home
        self.socketOverride = socketOverride
        self.defaults = defaults
        self.confirmAttach = confirmAttach
        self.register = register
        self.setChildSocket = setChildSocket
        self.make = make
    }
}

/// Owns the one live session and replaces it in place when the profile or
/// its server changes. Requests run one at a time, in arrival order.
@MainActor
@Observable
public final class ProfileSessionController<Session: ProfileSession> {
    public let profiles: ProfileStore
    public private(set) var session: Session
    /// Bumped on every completed switch; the window keys its content on it.
    public private(set) var generation: Int = 0
    public private(set) var socketPath: String
    /// What another Flock's record is compared against: the socket path, or a machine's key.
    public private(set) var attachKey: String
    /// The socket a confirmed switch is moving onto, from confirmation until
    /// `socketPath` holds it; the old session's teardown runs in between.
    public private(set) var switchingTo: String?
    /// The profile a confirmed switch is moving onto, over the same span as
    /// `switchingTo`; nil for a server change within the current profile.
    public private(set) var switchingToProfile: FlockProfile?

    @ObservationIgnored private let environment: ProfileSessionEnvironment<Session>
    @ObservationIgnored private var queue: Task<Bool, Never>?

    public var isLocked: Bool { environment.socketOverride != nil }

    public init(profiles: ProfileStore, environment: ProfileSessionEnvironment<Session>) {
        self.profiles = profiles
        self.environment = environment
        let profile = profiles.current
        let socket = environment.socketOverride.map { HerdrServerAddress.normalize($0, home: environment.home) }
            ?? HerdrServerAddress.normalize(profiles.socketPath(of: profile), home: environment.home)
        let isMachine = Self.isMachineSession(profile, environment: environment)
        environment.setChildSocket(isMachine ? nil : socket)
        session = environment.make(Self.context(for: profile, on: socket, environment: environment))
        socketPath = socket
        attachKey = Self.attachKey(for: profile, on: socket, environment: environment)
    }

    @discardableResult
    public func switchTo(profileID: String) async -> Bool {
        await enqueue { controller in await controller.performSwitch(to: profileID) }
    }

    @discardableResult
    public func changeServer(to socketPath: String?) async -> Bool {
        await enqueue { controller in await controller.performChangeServer(to: socketPath) }
    }

    private func enqueue(_ request: @escaping @MainActor (ProfileSessionController) async -> Bool) async -> Bool {
        let previous = queue
        let task = Task { @MainActor in
            _ = await previous?.value
            return await request(self)
        }
        queue = task
        return await task.value
    }

    private func performSwitch(to profileID: String) async -> Bool {
        guard !isLocked, profileID != profiles.currentID,
              let target = profiles.profiles.first(where: { $0.id == profileID }) else { return false }
        let newSocket = normalize(profiles.socketPath(of: target))
        let targetLabel = target.isMachine
            ? target.name
            : HerdrServerAddress(socketPath: newSocket, home: environment.home).label
        let key = Self.attachKey(for: target, on: newSocket, environment: environment)
        guard await environment.confirmAttach(key, targetLabel, profiles.current.name) else { return false }
        switchingTo = newSocket
        switchingToProfile = target
        await session.shutdown()
        profiles.select(profileID)
        await rebuild(on: newSocket)
        return true
    }

    private func performChangeServer(to requested: String?) async -> Bool {
        let newSocket = normalize(requested ?? environment.defaultSocketPath)
        guard !isLocked, !profiles.current.isMachine, newSocket != socketPath else { return false }
        let stayLabel = HerdrServerAddress(socketPath: socketPath, home: environment.home).label
        let targetLabel = HerdrServerAddress(socketPath: newSocket, home: environment.home).label
        guard await environment.confirmAttach(newSocket, targetLabel, stayLabel) else { return false }
        switchingTo = newSocket
        await session.shutdown()
        let isDefault = newSocket == normalize(environment.defaultSocketPath)
        profiles.setSocket(isDefault ? nil : newSocket, for: profiles.currentID)
        await rebuild(on: newSocket)
        return true
    }

    private func rebuild(on newSocket: String) async {
        let profile = profiles.current
        let key = Self.attachKey(for: profile, on: newSocket, environment: environment)
        environment.setChildSocket(Self.isMachineSession(profile, environment: environment) ? nil : newSocket)
        session = environment.make(Self.context(for: profile, on: newSocket, environment: environment))
        socketPath = newSocket
        attachKey = key
        switchingTo = nil
        switchingToProfile = nil
        environment.register(key)
        generation += 1
        await session.start()
    }

    private func normalize(_ path: String) -> String {
        HerdrServerAddress.normalize(path, home: environment.home)
    }

    /// An override binds the session to its socket, whatever the current profile is.
    private static func isMachineSession(_ profile: FlockProfile, environment: ProfileSessionEnvironment<Session>) -> Bool {
        environment.socketOverride == nil && profile.isMachine
    }

    private static func attachKey(
        for profile: FlockProfile,
        on socket: String,
        environment: ProfileSessionEnvironment<Session>
    ) -> String {
        isMachineSession(profile, environment: environment)
            ? ProfileSuites.attachKey(for: profile, socketPath: socket)
            : socket
    }

    private static func context(
        for profile: FlockProfile,
        on socket: String,
        environment: ProfileSessionEnvironment<Session>
    ) -> ProfileSessionContext {
        let preferences = environment.defaults(
            ProfileSuites.preferencesSuiteName(bundleID: environment.bundleID, profile: profile)
        )
        let idSuite = environment.socketOverride != nil
            ? ProfileSuites.overrideSuiteName(bundleID: environment.bundleID)
            : ProfileSuites.serverSuiteName(
                bundleID: environment.bundleID,
                profileID: profile.id,
                socketPath: socket,
                defaultSocketPath: HerdrServerAddress.normalize(environment.defaultSocketPath, home: environment.home)
            )
        return ProfileSessionContext(
            profile: profile,
            socketPath: socket,
            preferences: preferences,
            idState: environment.defaults(idSuite),
            isRemoteMachine: isMachineSession(profile, environment: environment)
        )
    }
}
