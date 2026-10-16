import Foundation

/// The last non-empty terminal title each agent session reported, so a pane
/// herdr stops reporting a title for (an idle pane after `update --handoff`)
/// keeps the name it had. Keyed by the session id, which a handoff keeps;
/// pane, tab and terminal ids do not all survive one.
public struct PaneTitleMemory: Codable, Equatable, Sendable {
    public static let capacity = 200

    private struct Entry: Codable, Equatable, Sendable {
        let sessionID: String
        var title: String
    }

    /// Least recently remembered first.
    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }

    public func title(for sessionID: String) -> String? {
        entries.last { $0.sessionID == sessionID }?.title
    }

    public mutating func remember(sessionID: String, title: String) {
        guard !sessionID.isEmpty, !title.isEmpty else { return }
        entries.removeAll { $0.sessionID == sessionID }
        entries.append(Entry(sessionID: sessionID, title: title))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Remembers every title `model` reports for a pane with a session.
    /// True when the memory changed: a title already remembered is left as it
    /// is, so a steady title costs no write.
    @discardableResult
    public mutating func observe(_ model: SessionModel) -> Bool {
        var changed = false
        for pane in model.panes.values {
            guard let session = pane.agentSessionID, let title = pane.terminalTitleStripped, !title.isEmpty,
                  self.title(for: session) != title
            else { continue }
            remember(sessionID: session, title: title)
            changed = true
        }
        return changed
    }

    /// `model` with each pane that has neither a name nor a title of its own
    /// carrying its session's remembered title.
    public func applying(to model: SessionModel) -> SessionModel {
        var result = model
        for (id, pane) in model.panes {
            let hasOwnTitle = [pane.label, pane.terminalTitleStripped].contains { !($0 ?? "").isEmpty }
            let remembered = hasOwnTitle ? nil : pane.agentSessionID.flatMap { title(for: $0) }
            if remembered != pane.rememberedTitle { result.panes[id]?.rememberedTitle = remembered }
        }
        return result
    }
}

/// Feeds `PaneTitleMemory` from every model update and keeps it in
/// UserDefaults. A title can change many times a second while an agent works,
/// so a changed memory is written once after `saveDelay`, not per update.
/// `userDefaults` nil keeps it in memory.
@MainActor
public final class PaneTitleStore {
    public static let defaultsKey = "flock.paneTitleMemory"

    private var memory: PaneTitleMemory
    private var dirty = false
    private var pendingSave: Task<Void, Never>?
    private let userDefaults: UserDefaults?
    private let saveDelay: Duration

    public init(userDefaults: UserDefaults? = nil, saveDelay: Duration = .seconds(2)) {
        self.userDefaults = userDefaults
        self.saveDelay = saveDelay
        memory = userDefaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(PaneTitleMemory.self, from: $0) } ?? PaneTitleMemory()
    }

    /// `model` after learning its titles, carrying the remembered title for
    /// each pane that has none.
    public func apply(to model: SessionModel) -> SessionModel {
        if memory.observe(model) { scheduleSave() }
        return memory.applying(to: model)
    }

    /// Writes a changed memory now.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty, let userDefaults, let data = try? JSONEncoder().encode(memory) else { return }
        dirty = false
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    private func scheduleSave() {
        guard userDefaults != nil else { return }
        dirty = true
        guard pendingSave == nil else { return }
        let delay = saveDelay
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
