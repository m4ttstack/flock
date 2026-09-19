/// What a fan-out is worth telling the user. `delivered` is rt's own word,
/// and only `"refused"` is a failure: a queued message is one rt has taken
/// responsibility for, so reporting it as failed would send the user
/// chasing a message that already arrived.
public enum ChatBroadcastSummary {
    public static func message(for broadcast: ChatBroadcast) -> String? {
        let refused = broadcast.results.filter { $0.delivered == "refused" }
        guard !refused.isEmpty else { return nil }
        if refused.count == broadcast.results.count {
            return "Every pane refused the broadcast"
        }
        let names = refused.map(\.paneID).joined(separator: ", ")
        return "Refused by \(names)"
    }
}
