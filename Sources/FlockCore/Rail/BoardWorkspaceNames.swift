import Foundation

/// The herdr workspaces the board app launches its panes into, one per role,
/// as the `board.workspaces` setting names them.
///
/// Board finds these workspaces by label and nothing else, so the label is
/// the whole of membership: a workspace is Board's when its label is one of
/// these names exactly.
public struct BoardWorkspaceNames: Equatable, Sendable {
    public let reviews: String
    public let responds: String
    public let doctors: String

    /// Board's own fallbacks, field by field (`src/config.ts` in the board
    /// app), for a setting that leaves a role out.
    public static let defaults = BoardWorkspaceNames(reviews: "reviews", responds: "responses", doctors: "doctors")

    public init(reviews: String, responds: String, doctors: String) {
        self.reviews = reviews
        self.responds = responds
        self.doctors = doctors
    }

    /// Role order, each name once: two roles sharing a workspace list it once.
    public var labels: [String] {
        var seen = Set<String>()
        return [reviews, responds, doctors].filter { seen.insert($0).inserted }
    }

    public func contains(label: String) -> Bool {
        label == reviews || label == responds || label == doctors
    }

    /// What `rt settings get board.workspaces --json` answered, or nil for no
    /// Board config at all: a non-zero exit, `ok:false`, or output that is not
    /// the envelope. An unset setting is `ok:true` with no `value` (rt drops
    /// an undefined value from its JSON), which board reads as every default.
    public static func fromSettingsGet(stdout: Data, exitCode: Int32) -> BoardWorkspaceNames? {
        guard exitCode == 0,
              let envelope = try? JSONDecoder().decode(SettingsGetEnvelope.self, from: stdout),
              envelope.ok
        else { return nil }
        let value = envelope.value
        return BoardWorkspaceNames(
            reviews: value?.reviews ?? defaults.reviews,
            responds: value?.responds ?? defaults.responds,
            doctors: value?.doctors ?? defaults.doctors
        )
    }
}

private struct SettingsGetEnvelope: Decodable {
    let ok: Bool
    let value: Roles?

    /// A value that is not an object fails the whole decode, which is the
    /// unparseable case. Inside one, a role that is missing, null, empty or
    /// not a string is simply left to its default.
    struct Roles: Decodable {
        let reviews: String?
        let responds: String?
        let doctors: String?

        private enum CodingKeys: String, CodingKey {
            case reviews, responds, doctors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func name(_ key: CodingKeys) -> String? {
                guard let value = try? container.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
                return value
            }
            reviews = name(.reviews)
            responds = name(.responds)
            doctors = name(.doctors)
        }
    }
}
