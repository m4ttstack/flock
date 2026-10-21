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

    public init(profile: FlockProfile, socketPath: String, preferences: UserDefaults, idState: UserDefaults) {
        self.profile = profile
        self.socketPath = socketPath
        self.preferences = preferences
        self.idState = idState
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
    public var confirmAttach: @MainActor (_ socketPath: String, _ stayLabel: String) async -> Bool
    public var register: @MainActor (_ socketPath: String) -> Void
    public var setChildSocket: (_ socketPath: String) -> Void
    public var make: @MainActor (ProfileSessionContext) -> Session

    public init(
        bundleID: String,
        defaultSocketPath: String,
        home: String,
        socketOverride: String?,
        defaults: @escaping @MainActor (_ suiteName: String?) -> UserDefaults,
        confirmAttach: @escaping @MainActor (_ socketPath: String, _ stayLabel: String) async -> Bool,
        register: @escaping @MainActor (_ socketPath: String) -> Void,
        setChildSocket: @escaping (_ socketPath: String) -> Void,
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
    /// The socket a confirmed switch is moving onto, from confirmation until
    /// `socketPath` holds it; the old session's teardown runs in between.
    public private(set) var switchingTo: String?

    @ObservationIgnored private let environment: ProfileSessionEnvironment<Session>
    @ObservationIgnored private var queue: Task<Bool, Never>?

    public var isLocked: Bool { environment.socketOverride != nil }

    public init(profiles: ProfileStore, environment: ProfileSessionEnvironment<Session>) {
        self.profiles = profiles
        self.environment = environment
        let profile = profiles.current
        let socket = environment.socketOverride.map { HerdrServerAddress.normalize($0, home: environment.home) }
            ?? HerdrServerAddress.normalize(profiles.socketPath(of: profile), home: environment.home)
        environment.setChildSocket(socket)
        session = environment.make(Self.context(for: profile, on: socket, environment: environment))
        socketPath = socket
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
        guard await environment.confirmAttach(newSocket, profiles.current.name) else { return false }
        switchingTo = newSocket
        await session.shutdown()
        profiles.select(profileID)
        await rebuild(on: newSocket)
        return true
    }

    private func performChangeServer(to requested: String?) async -> Bool {
        let newSocket = normalize(requested ?? environment.defaultSocketPath)
        guard !isLocked, newSocket != socketPath else { return false }
        let stayLabel = HerdrServerAddress(socketPath: socketPath, home: environment.home).label
        guard await environment.confirmAttach(newSocket, stayLabel) else { return false }
        switchingTo = newSocket
        await session.shutdown()
        let isDefault = newSocket == normalize(environment.defaultSocketPath)
        profiles.setSocket(isDefault ? nil : newSocket, for: profiles.currentID)
        await rebuild(on: newSocket)
        return true
    }

    private func rebuild(on newSocket: String) async {
        environment.setChildSocket(newSocket)
        session = environment.make(Self.context(for: profiles.current, on: newSocket, environment: environment))
        socketPath = newSocket
        switchingTo = nil
        environment.register(newSocket)
        generation += 1
        await session.start()
    }

    private func normalize(_ path: String) -> String {
        HerdrServerAddress.normalize(path, home: environment.home)
    }

    private static func context(
        for profile: FlockProfile,
        on socket: String,
        environment: ProfileSessionEnvironment<Session>
    ) -> ProfileSessionContext {
        let preferences = environment.defaults(
            ProfileSuites.preferencesSuiteName(bundleID: environment.bundleID, profileID: profile.id)
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
            idState: environment.defaults(idSuite)
        )
    }
}
