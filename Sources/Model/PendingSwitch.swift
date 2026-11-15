import Foundation

/// A switch that has started writing Claude Code's login and hasn't been
/// verified or rolled back yet. No secrets: account ids and a time.
struct PendingSwitch: Codable, Equatable, Sendable {
    let fromId: String
    let toId: String
    let startedAt: Date
}

/// Where the pending-switch journal lives. A switch writes it before
/// changing Claude's Keychain item and clears it once the result (or a
/// rollback) verifies. Finding it on launch means a switch was interrupted.
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
