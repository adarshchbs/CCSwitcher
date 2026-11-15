import Foundation

/// A saved Claude login, as shown in the menu. Holds no secrets: the tokens
/// live in the account's own Keychain item (see `AccountStore`).
///
/// Identity is `orgUuid`. Two logins can share one email address (a company
/// Team org and a personal org), so email never identifies an account.
struct SavedAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var email: String
    var orgUuid: String
    var orgName: String?
    /// `subscriptionType` from the login (`team`, `max`, …).
    var plan: String?
    /// The rate-limit tier (`default_claude_max_20x`, …), from the login,
    /// `~/.claude.json` or the profile endpoint. Absent in accounts saved
    /// before it was recorded; filled in on the next proven profile check.
    var rateLimitTier: String? = nil
}

extension SavedAccount {
    init(id: String, label: String, email: String, orgUuid: String) {
        self.init(id: id, label: label, email: email, orgUuid: orgUuid, orgName: nil, plan: nil)
    }
}

extension Array where Element == SavedAccount {
    /// The saved account that owns a login from organization `orgUuid`, or nil
    /// when no saved account matches. More than one match is treated as no
    /// match: the owner would be ambiguous, and the caller must then refuse.
    func owner(ofOrg orgUuid: String?) -> SavedAccount? {
        guard let orgUuid, !orgUuid.isEmpty else { return nil }
        let matches = filter { $0.orgUuid == orgUuid }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// The `oauthAccount` block of `~/.claude.json`, kept whole so a switch writes
/// back exactly the block that was saved.
struct OAuthProfile: Sendable {
    let fields: [String: AnyCodable]

    var organizationUuid: String? { string("organizationUuid") }
    var emailAddress: String? { string("emailAddress") }
    var organizationName: String? { string("organizationName") }
    /// The organization's rate-limit tier, else the user's.
    var rateLimitTier: String? { string("organizationRateLimitTier") ?? string("userRateLimitTier") }

    /// The block as canonical JSON (sorted keys), to tell whether two
    /// profiles hold the same fields.
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields)
    }

    private func string(_ key: String) -> String? {
        guard let value = fields[key]?.value as? String, !value.isEmpty else { return nil }
        return value
    }
}

/// Where the saved-account metadata lives.
protocol AccountList: Sendable {
    func load() throws -> [SavedAccount]
    func save(_ accounts: [SavedAccount]) throws
}

/// `AccountList` in `UserDefaults`, key `accounts.v1`.
struct DefaultsAccountList: AccountList, @unchecked Sendable {
    // `UserDefaults` is thread-safe; it just isn't annotated Sendable.
    let defaults: UserDefaults
    let key = "accounts.v1"

    func load() throws -> [SavedAccount] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([SavedAccount].self, from: data)
    }

    func save(_ accounts: [SavedAccount]) throws {
        defaults.set(try JSONEncoder().encode(accounts), forKey: key)
    }
}
