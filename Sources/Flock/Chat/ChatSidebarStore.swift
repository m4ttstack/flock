import FlockCore
import Foundation
import Observation

/// Which Slack chat the right sidebar shows and where its page lives.
///
/// A chat can start or end from the pane, the chat app or Slack, none of which
/// tell Flock, so this reads rt on a timer for as long as `follow()` runs.
@MainActor
@Observable
final class ChatSidebarStore {
    static let interval: Duration = .seconds(5)

    private(set) var selection: ChatSidebarSelection?
    private(set) var embedURL: URL?
    private(set) var chatAppIsDown = false
    private(set) var isCollapsed = false
    private(set) var tabPanes: Set<String> = []

    /// Each read of rt, before the links below are applied.
    @ObservationIgnored var onChats: (([ChatSidebarChat]) async -> Void)?
    /// The pane a background agent was started from.
    @ObservationIgnored var owner: ((String) -> String?)?

    @ObservationIgnored private var focusedPane: String?
    @ObservationIgnored private var port: Int?
    @ObservationIgnored private let readChats: @Sendable () async -> [ChatSidebarChat]?
    @ObservationIgnored private let readPort: @Sendable () async -> Int?
    @ObservationIgnored private let pause: (Duration) async throws -> Void

    init(
        readChats: @escaping @Sendable () async -> [ChatSidebarChat]? = ChatToolLocator.slackChats,
        readPort: @escaping @Sendable () async -> Int? = ChatToolLocator.chatAppPort,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.readChats = readChats
        self.readPort = readPort
        self.pause = pause
    }

    func follow() async {
        while !Task.isCancelled {
            await refresh()
            do { try await pause(Self.interval) } catch { return }
        }
    }

    func focusChanged(to pane: String?) async {
        focusedPane = pane
        await refresh()
    }

    func tabChanged(to panes: Set<String>) async {
        tabPanes = panes
        await refresh()
    }

    func refresh() async {
        guard let open = await readChats(), !Task.isCancelled else { return }
        await onChats?(open)
        let linked = open.map { chat in
            var chat = chat
            chat.linkedPane = chat.pane.flatMap { owner?($0) }
            return chat
        }
        await select(
            ChatSidebarSelection.next(current: selection, open: linked, focusedPane: focusedPane, tabPanes: tabPanes)
        )
    }

    func toggleCollapsed() {
        isCollapsed.toggle()
    }

    /// An ended chat has nothing left to come back to.
    func close() {
        selection = nil
        embedURL = nil
        isCollapsed = false
    }

    /// The port may have moved, or the app may have just come up.
    func embedFailed() {
        port = nil
        embedURL = nil
        chatAppIsDown = true
    }

    func retry() async {
        chatAppIsDown = false
        await select(selection)
    }

    private func select(_ next: ChatSidebarSelection?) async {
        selection = next
        guard let room = next?.chat.room else {
            embedURL = nil
            chatAppIsDown = false
            return
        }
        if embedURL?.lastPathComponent == room { return }
        guard !chatAppIsDown else { return }
        if port == nil { port = await readPort() }
        guard let port else {
            chatAppIsDown = true
            return
        }
        embedURL = ChatEmbedAddress.url(port: port, room: room)
    }
}
