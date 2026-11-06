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
    private var syncedMachineIDs: Set<String>?

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let defaultSocketPath: String
    @ObservationIgnored private let home: String
    @ObservationIgnored private let removeSuite: (String) -> Void
    @ObservationIgnored private let machineSocketPath: (HerdrMachine) -> String

    private struct Stored: Codable {
        var profiles: [FlockProfile]
        var currentID: String
    }

    public init(
        userDefaults: UserDefaults = .standard,
        bundleID: String,
        defaultSocketPath: String,
        home: String = NSHomeDirectory(),
        removeSuite: @escaping (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) },
        machineSocketPath: @escaping (HerdrMachine) -> String = { _ in "" }
    ) {
        self.userDefaults = userDefaults
        self.bundleID = bundleID
        self.defaultSocketPath = defaultSocketPath
        self.home = home
        self.removeSuite = removeSuite
        self.machineSocketPath = machineSocketPath
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

    /// True when the last `syncMachines` list lacked the current machine profile's machine.
    public var currentMachineMissing: Bool {
        guard let machine = current.machine, let synced = syncedMachineIDs else { return false }
        return !synced.contains(machine.id)
    }

    public func socketPath(of profile: FlockProfile) -> String {
        if let machine = profile.machine { return machineSocketPath(machine) }
        return profile.socketPath ?? defaultSocketPath
    }

    /// Upserts one profile per machine, after the user's profiles. A machine
    /// missing from the list is dropped unless its profile is current.
    public func syncMachines(_ machines: [HerdrMachine]) {
        let byID = Dictionary(machines.map { ("machine.\($0.id)", $0) }, uniquingKeysWith: { _, last in last })
        var kept: [FlockProfile] = []
        for var profile in profiles {
            guard profile.isMachine else {
                kept.append(profile)
                continue
            }
            if let machine = byID[profile.id] {
                profile.name = machine.label
                profile.machine = machine
                kept.append(profile)
            } else if profile.id == currentID {
                kept.append(profile)
            } else if let gone = profile.machine {
                dropIDState(of: gone, profileID: profile.id)
            }
        }
        for machine in machines {
            let id = "machine.\(machine.id)"
            guard !kept.contains(where: { $0.id == id }) else { continue }
            kept.append(FlockProfile(id: id, name: machine.label, socketPath: nil, knownSockets: [], machine: machine))
        }
        syncedMachineIDs = Set(machines.map(\.id))
        guard kept != profiles else { return }
        profiles = kept
        save()
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
        profiles.insert(profile, at: profiles.firstIndex(where: \.isMachine) ?? profiles.endIndex)
        save()
        return profile
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isMachine else { return }
        profiles[index].name = trimmed
        save()
    }

    public func setSocket(_ socketPath: String?, for id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isMachine else { return }
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
              let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isMachine else { return false }
        let profile = profiles.remove(at: index)
        for name in ProfileSuites.allSuiteNames(for: profile, bundleID: bundleID, defaultSocketPath: defaultSocketPath) {
            removeSuite(name)
        }
        save()
        return true
    }

    private func dropIDState(of machine: HerdrMachine, profileID: String) {
        let suite = ProfileSuites.serverSuiteName(
            bundleID: bundleID,
            profileID: profileID,
            socketPath: machineSocketPath(machine),
            defaultSocketPath: defaultSocketPath
        )
        if let suite { removeSuite(suite) }
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(profiles: profiles, currentID: currentID))
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
