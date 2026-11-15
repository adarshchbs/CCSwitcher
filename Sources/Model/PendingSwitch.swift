import Foundation

/// An operation that has started changing Claude Code's login and hasn't been
/// verified, rolled back or settled yet. No secrets: account ids, a kind and
/// a time.
struct PendingSwitch: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A switch from `fromId` to `toId`.
        case `switch`
        /// Add account: `claude auth login` was about to run while `fromId`
        /// was live. `toId` is nil: the new login's account isn't known yet.
        case login
    }

    let fromId: String
    let toId: String?
    let kind: Kind
    let startedAt: Date

    init(fromId: String, toId: String?, kind: Kind = .switch, startedAt: Date) {
        self.fromId = fromId
        self.toId = toId
        self.kind = kind
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case fromId, toId, kind, startedAt
    }

    /// Journals written before `kind` existed decode as switches.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromId = try container.decode(String.self, forKey: .fromId)
        toId = try container.decodeIfPresent(String.self, forKey: .toId)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .switch
        startedAt = try container.decode(Date.self, forKey: .startedAt)
    }
}

/// Where the pending-switch journal lives. A switch writes it before
/// changing Claude's Keychain item and clears it once the result (or a
/// rollback) verifies; Add account writes it before running
/// `claude auth login` and clears it once the result is settled. Finding it
/// on launch means one of them was interrupted.
protocol SwitchJournal: Sendable {
    func load() throws -> PendingSwitch?
    func save(_ pending: PendingSwitch) throws
    func clear()
}

/// `SwitchJournal` in `UserDefaults`, key `pendingSwitch.v1`.
struct DefaultsSwitchJournal: SwitchJournal, @unchecked Sendable {
    // `UserDefaults` is thread-safe; it just isn't annotated Sendable.
    let defaults: UserDefaults
    let key = "pendingSwitch.v1"

    func load() throws -> PendingSwitch? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(PendingSwitch.self, from: data)
    }

    func save(_ pending: PendingSwitch) throws {
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
