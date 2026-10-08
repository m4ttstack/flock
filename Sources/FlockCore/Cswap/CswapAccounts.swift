import Foundation

/// How a pin names a cswap account. cswap's own key is email plus
/// organization: one email can sit in two organizations, and the numbers
/// change on `swap` and `move`.
public struct ClaudeAccountRef: Codable, Hashable, Sendable {
    public let email: String
    /// nil on a pin saved before the organization was stored; it then
    /// matches the first account with the email.
    public let organizationUuid: String?

    public init(email: String, organizationUuid: String?) {
        self.email = email
        self.organizationUuid = organizationUuid
    }
}

/// One account `cswap list --json` reports.
public struct CswapAccount: Equatable, Sendable {
    public let number: Int
    public let email: String
    public let organizationName: String?
    public let organizationUuid: String?
    public let alias: String?

    public init(number: Int, email: String, organizationName: String?, organizationUuid: String?, alias: String?) {
        self.number = number
        self.email = email
        self.organizationName = organizationName
        self.organizationUuid = organizationUuid
        self.alias = alias
    }

    public var ref: ClaudeAccountRef {
        ClaudeAccountRef(email: email, organizationUuid: organizationUuid)
    }

    /// cswap names a personal account's organization "<email>'s Organization",
    /// which repeats the email.
    public var label: String {
        if let alias, !alias.isEmpty { return alias }
        guard let organizationName, !organizationName.isEmpty, organizationName != "\(email)'s Organization" else {
            return email
        }
        return "\(email) \u{00B7} \(organizationName)"
    }

    func matches(_ ref: ClaudeAccountRef) -> Bool {
        email.caseInsensitiveCompare(ref.email) == .orderedSame
            && (ref.organizationUuid == nil || ref.organizationUuid == organizationUuid)
    }
}

extension [CswapAccount] {
    func first(matching ref: ClaudeAccountRef) -> CswapAccount? {
        first { $0.matches(ref) }
    }
}

public enum CswapAccountList {
    public static let schemaVersion = 1

    private struct Listing: Decodable {
        let schemaVersion: Int
        let accounts: [Row]
    }

    private struct Row: Decodable {
        let number: Int
        let email: String
        let organizationName: String?
        let organizationUuid: String?
        let alias: String?
    }

    /// nil for anything but a listing of the schema this reads.
    public static func parse(_ data: Data) -> [CswapAccount]? {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing.schemaVersion == schemaVersion else { return nil }
        return listing.accounts.map {
            CswapAccount(
                number: $0.number, email: $0.email, organizationName: $0.organizationName,
                organizationUuid: $0.organizationUuid, alias: $0.alias
            )
        }
    }
}

public struct ClaudeLaunchLine: Equatable, Sendable {
    /// Why the pin's account was set but not used; each carries its email.
    public enum Fallback: Equatable, Sendable {
        case notInCswap(String)
        case cswapUnreadable(String)
    }

    public let text: String
    public let fallback: Fallback?

    public init(text: String, fallback: Fallback?) {
        self.text = text
        self.fallback = fallback
    }
}

public enum ClaudeAccountLaunch {
    public static let claudeBinary = "claude"

    /// `accounts` is nil when cswap is not installed or could not be read.
    /// The account runs by number, read fresh at launch, since `cswap run`
    /// refuses an email two organizations share.
    public static func line(binary: String, account: ClaudeAccountRef?, accounts: [CswapAccount]?) -> ClaudeLaunchLine {
        guard binary == claudeBinary, let account else { return ClaudeLaunchLine(text: binary, fallback: nil) }
        guard let accounts else { return ClaudeLaunchLine(text: binary, fallback: .cswapUnreadable(account.email)) }
        guard let known = accounts.first(matching: account) else {
            return ClaudeLaunchLine(text: binary, fallback: .notInCswap(account.email))
        }
        return ClaudeLaunchLine(text: "cswap run \(known.number)", fallback: nil)
    }

    public static func notice(pinName: String, fallback: ClaudeLaunchLine.Fallback) -> String {
        switch fallback {
        case .notInCswap(let email):
            "\"\(pinName)\"'s account \(email) isn't in cswap; Claude launched on the current login."
        case .cswapUnreadable(let email):
            "cswap couldn't be read, so \"\(pinName)\"'s account \(email) wasn't used; Claude launched on the current login."
        }
    }
}

/// The Claude Account submenu a pin offers.
public enum ClaudeAccountMenu {
    public struct Entry: Equatable, Sendable {
        public let label: String
        /// nil for the current login.
        public let account: ClaudeAccountRef?
        public let isChecked: Bool

        public init(label: String, account: ClaudeAccountRef?, isChecked: Bool) {
            self.label = label
            self.account = account
            self.isChecked = isChecked
        }
    }

    public static let title = "Claude Account"

    /// Empty when cswap was not detected, which leaves the pin with no submenu.
    public static func entries(saved: ClaudeAccountRef?, accounts: [CswapAccount]?) -> [Entry] {
        guard let accounts else { return [] }
        let checked = saved.flatMap { accounts.first(matching: $0) }
        var entries = [Entry(label: "Current Login", account: nil, isChecked: saved == nil)]
        entries += accounts.map { account in
            Entry(label: account.label, account: account.ref, isChecked: account == checked)
        }
        if let saved, checked == nil {
            entries.append(Entry(label: "\(saved.email) (not in cswap)", account: saved, isChecked: true))
        }
        return entries
    }
}
