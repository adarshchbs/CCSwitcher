import Foundation

/// One change of the live login's owner. No secrets: a time, an account id
/// and who made the change.
struct LoginChange: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// The app switched (or restored) the login.
        case `switch`
        /// The app's Add account signed in.
        case add
        /// The app saw the owner change without having caused it: a
        /// `claude /login` in a terminal, or a running session writing its
        /// old login back.
        case external
    }

    /// For an external change, the Keychain item's modification date.
    var at: Date
    /// nil: an organization that isn't saved.
    var accountId: String?
    var source: Source
}

protocol LoginHistoryStore: Sendable {
    func load() throws -> [LoginChange]
    func save(_ history: [LoginChange]) throws
}

/// `LoginHistoryStore` in `UserDefaults`, key `loginHistory.v1`.
struct DefaultsLoginHistory: LoginHistoryStore, @unchecked Sendable {
    // `UserDefaults` is thread-safe; it just isn't annotated Sendable.
    let defaults: UserDefaults
    static let key = "loginHistory.v1"

    func load() throws -> [LoginChange] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try JSONDecoder().decode([LoginChange].self, from: data)
    }

    func save(_ history: [LoginChange]) throws {
        defaults.set(try JSONEncoder().encode(history), forKey: Self.key)
    }
}

/// Which account a running session got: the one live when it started.
enum SessionAccount: Hashable, Sendable {
    case account(String)
    /// Started before the first history entry, start time unreadable, or
    /// started while an unsaved organization was live.
    case unknown
}

enum LoginHistory {
    static let limit = 20

    /// `history` plus `change`, in time order, keeping the last `limit`.
    static func appending(_ change: LoginChange, to history: [LoginChange]) -> [LoginChange] {
        let sorted = (history + [change]).enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        return Array(sorted.suffix(limit))
    }

    /// The account live at `date`: the last change at or before it.
    static func account(at date: Date?, in history: [LoginChange]) -> SessionAccount {
        guard let date, let change = history.last(where: { $0.at <= date }), let id = change.accountId else {
            return .unknown
        }
        return .account(id)
    }

    /// When the last change was made outside the app, if it's the one that
    /// made `ownerId` live. The very first entry doesn't count: it records
    /// the owner the app found, not a change it saw.
    static func externalChange(in history: [LoginChange], ownerId: String?) -> Date? {
        guard history.count >= 2, let last = history.last, last.source == .external,
              let ownerId, last.accountId == ownerId else { return nil }
        return last.at
    }
}

/// Which accounts the running Claude sessions started on. An estimate:
/// a session loads its login at startup and keeps it, unless Claude Code's
/// sibling-login watcher adopts the new one (not every session does).
struct RunningSessions: Equatable, Sendable {
    /// Sessions per account they started on.
    var byAccount: [String: Int] = [:]
    var unknown = 0
    /// Accounts other than the live owner that running sessions started on.
    var warnings: [Warning] = []

    struct Warning: Equatable, Sendable {
        var accountId: String
        var count: Int
        /// When the current owner became live, if the history says.
        var liveSince: Date?
        /// That account's saved access token's expiry: about when those
        /// sessions refresh it and may write it back to the Keychain.
        var writeBackAround: Date?
    }

    var total: Int { byAccount.values.reduce(unknown, +) }

    /// Warnings need a proven live owner: without one there's nothing to
    /// compare against.
    static func compute(sessions: [LiveSession], history: [LoginChange], liveOwnerId: String?,
                        savedExpiry: [String: Date], now: Date) -> RunningSessions {
        var result = RunningSessions()
        for session in sessions {
            switch LoginHistory.account(at: session.startedAt, in: history) {
            case .account(let id): result.byAccount[id, default: 0] += 1
            case .unknown: result.unknown += 1
            }
        }
        guard let liveOwnerId else { return result }
        let liveSince = history.last.flatMap { $0.accountId == liveOwnerId ? $0.at : nil }
        result.warnings = result.byAccount.keys.filter { $0 != liveOwnerId }.sorted().map { id in
            Warning(accountId: id, count: result.byAccount[id] ?? 0, liveSince: liveSince,
                    writeBackAround: savedExpiry[id].flatMap { $0 > now ? $0 : nil })
        }
        return result
    }
}
