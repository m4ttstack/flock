import Foundation

/// What `status` prints: whether this pane is signed in, and to what.
public struct ChatStatus: Decodable, Equatable, Sendable {
    public let handle: String?
    public let state: String
    public let pane: String?
    public let signedIn: Bool
    public let rooms: [String]
}

/// What `peek` prints: everyone visible, and every room's unread count.
public struct ChatPeek: Decodable, Equatable, Sendable {
    public let buddies: [ChatBuddy]
    public let rooms: [ChatPeekRoom]
}

/// One buddy on the list.
public struct ChatBuddy: Decodable, Equatable, Sendable {
    public let handle: String
    public let paneID: String
    public let status: String
    public let repo: String?
    public let branch: String?
    public let title: String?
    public let unread: Int
    public let mentions: Int

    private enum CodingKeys: String, CodingKey {
        case handle, status, repo, branch, title, unread, mentions
        case paneID = "paneId"
    }
}

/// One room's unread tally, as `peek` reports it.
public struct ChatPeekRoom: Decodable, Equatable, Sendable {
    public let room: String
    public let unread: Int
    public let mentions: Int
}

/// What `targets` prints: every room and person a send could name.
public struct ChatTargets: Decodable, Equatable, Sendable {
    public let rooms: [String]
    public let people: [String]
}

/// What `quick-send` prints. The far side always answers `ok: true` here,
/// so `ok` is not a field: decoding it would invite a branch on a value
/// that never varies.
public struct ChatSent: Decodable, Equatable, Sendable {
    public let to: String
}

/// What `broadcast` prints: one result per pane, plus whether every pane
/// took delivery.
public struct ChatBroadcast: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let results: [ChatBroadcastResult]
}

/// One pane's answer within a broadcast.
public struct ChatBroadcastResult: Decodable, Equatable, Sendable {
    public let paneID: String
    public let ok: Bool
    public let delivered: String
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok, delivered, error
        case paneID = "paneId"
    }
}

/// What `jump` prints: where to focus to reach the named handle.
public struct ChatJump: Decodable, Equatable, Sendable {
    public let paneID: String
    public let workspace: String
    public let handle: String

    private enum CodingKeys: String, CodingKey {
        case workspace, handle
        case paneID = "paneId"
    }
}

/// What `open-viewer` prints: the URL it opened.
public struct ChatViewer: Decodable, Equatable, Sendable {
    public let url: String
}
