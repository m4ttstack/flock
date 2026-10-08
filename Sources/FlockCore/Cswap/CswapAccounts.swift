import Foundation

/// One account `cswap list --json` reports. The email is what a pin stores:
/// cswap renumbers accounts on `swap` and `move`.
public struct CswapAccount: Equatable, Sendable {
    public let number: Int
    public let email: String
    public let organizationName: String?
    public let alias: String?

    public init(number: Int, email: String, organizationName: String?, alias: String?) {
        self.number = number
        self.email = email
        self.organizationName = organizationName
        self.alias = alias
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

    func matches(_ email: String) -> Bool {
        self.email.caseInsensitiveCompare(email) == .orderedSame
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
        let alias: String?
    }

    /// nil for anything but a listing of the schema this reads.
    public static func parse(_ data: Data) -> [CswapAccount]? {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing.schemaVersion == schemaVersion else { return nil }
        return listing.accounts.map {
            CswapAccount(number: $0.number, email: $0.email, organizationName: $0.organizationName, alias: $0.alias)
        }
    }
}

public struct ClaudeLaunchLine: Equatable, Sendable {
    public let text: String
    /// The pin's account, when it was set but cswap could not run it.
    public let unavailableAccount: String?

    public init(text: String, unavailableAccount: String?) {
        self.text = text
        self.unavailableAccount = unavailableAccount
    }
}

public enum ClaudeAccountLaunch {
    public static let claudeBinary = "claude"

    /// `accounts` is nil when cswap is not installed or could not be read.
    public static func line(binary: String, account: String?, accounts: [CswapAccount]?) -> ClaudeLaunchLine {
        guard binary == claudeBinary, let account else { return ClaudeLaunchLine(text: binary, unavailableAccount: nil) }
        guard let known = accounts?.first(where: { $0.matches(account) }) else {
            return ClaudeLaunchLine(text: binary, unavailableAccount: account)
        }
        return ClaudeLaunchLine(text: "cswap run \(RtCommandLine.quoted(known.email))", unavailableAccount: nil)
    }

    public static func notice(pinName: String, account: String) -> String {
        "\"\(pinName)\"'s account \(account) isn't in cswap; Claude launched on the current login."
    }
}

/// The Claude Account submenu a pin offers.
public enum ClaudeAccountMenu {
    public struct Entry: Equatable, Sendable {
        public let label: String
        /// nil for the current login.
        public let account: String?
        public let isChecked: Bool

        public init(label: String, account: String?, isChecked: Bool) {
            self.label = label
            self.account = account
            self.isChecked = isChecked
        }
    }

    public static let title = "Claude Account"

    /// Empty when cswap was not detected, which leaves the pin with no submenu.
    public static func entries(saved: String?, accounts: [CswapAccount]?) -> [Entry] {
        guard let accounts else { return [] }
        var entries = [Entry(label: "Current Login", account: nil, isChecked: saved == nil)]
        entries += accounts.map { account in
            Entry(label: account.label, account: account.email, isChecked: saved.map(account.matches) ?? false)
        }
        if let saved, !accounts.contains(where: { $0.matches(saved) }) {
            entries.append(Entry(label: "\(saved) (not in cswap)", account: saved, isChecked: true))
        }
        return entries
    }
}
