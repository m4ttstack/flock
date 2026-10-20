import Foundation
import Observation

/// The profile list and which one is current, persisted as one JSON value.
/// Nothing is written until the first change.
@MainActor
@Observable
public final class ProfileStore {
    public static let defaultsKey = "flock.profiles"

    public private(set) var profiles: [FlockProfile]
    public private(set) var currentID: String

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let defaultSocketPath: String
    @ObservationIgnored private let home: String
    @ObservationIgnored private let removeSuite: (String) -> Void

    private struct Stored: Codable {
        var profiles: [FlockProfile]
        var currentID: String
    }

    public init(
        userDefaults: UserDefaults = .standard,
        bundleID: String,
        defaultSocketPath: String,
        home: String = NSHomeDirectory(),
        removeSuite: @escaping (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) }
    ) {
        self.userDefaults = userDefaults
        self.bundleID = bundleID
        self.defaultSocketPath = defaultSocketPath
        self.home = home
        self.removeSuite = removeSuite
        let stored = userDefaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        var loaded = stored?.profiles ?? []
        if !loaded.contains(where: { $0.id == FlockProfile.defaultID }) {
            loaded.insert(
                FlockProfile(id: FlockProfile.defaultID, name: "Default", socketPath: nil, knownSockets: [defaultSocketPath]),
                at: 0
            )
        }
        profiles = loaded
        currentID = loaded.contains { $0.id == stored?.currentID } ? stored!.currentID : FlockProfile.defaultID
    }

    public var current: FlockProfile {
        profiles.first { $0.id == currentID } ?? profiles[0]
    }

    public func socketPath(of profile: FlockProfile) -> String {
        profile.socketPath ?? defaultSocketPath
    }

    public func create(name: String, socketPath: String?) -> FlockProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = socketPath.map { HerdrServerAddress.normalize($0, home: home) }
        let profile = FlockProfile(
            id: UUID().uuidString.lowercased(),
            name: trimmed,
            socketPath: normalized,
            knownSockets: [normalized ?? defaultSocketPath]
        )
        profiles.append(profile)
        save()
        return profile
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        save()
    }

    public func setSocket(_ socketPath: String?, for id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let normalized = socketPath.map { HerdrServerAddress.normalize($0, home: home) }
        profiles[index].socketPath = normalized
        let used = normalized ?? defaultSocketPath
        if !profiles[index].knownSockets.contains(used) {
            profiles[index].knownSockets.append(used)
        }
        save()
    }

    public func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        currentID = id
        save()
    }

    public func delete(_ id: String) -> Bool {
        guard id != FlockProfile.defaultID, id != currentID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let profile = profiles.remove(at: index)
        for name in ProfileSuites.allSuiteNames(for: profile, bundleID: bundleID, defaultSocketPath: defaultSocketPath) {
            removeSuite(name)
        }
        save()
        return true
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(profiles: profiles, currentID: currentID))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
