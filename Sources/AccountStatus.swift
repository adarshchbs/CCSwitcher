import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "AccountStatus")

/// Reads who owns the live login, and the usage tokens. `Switcher` in the app.
protocol LiveStateSource: Sendable {
    func liveState() async throws -> LiveState
}

extension Switcher: LiveStateSource {}

/// What the menu shows about the accounts: the live login's owner, usage
/// per account, the login-change history and the running sessions.
///
/// Nothing here runs on its own. `refresh` (menu open and "Refresh usage")
/// is the only path that fetches usage or recomputes the running sessions;
/// `reloadLive` (at launch and after an operation the user clicked) reads
/// the owner only. No timers, no polling, no cooldown.
@MainActor
final class AccountStatus: ObservableObject {
    @Published private(set) var live: LiveState?
    @Published private(set) var usage: [String: AccountUsage]
    /// Accounts whose usage request is running.
    @Published private(set) var fetching: Set<String> = []
    @Published private(set) var history: [LoginChange]
    @Published private(set) var sessions = RunningSessions()

    private let source: LiveStateSource
    private let client: UsageClient
    private let cache: UsageCache
    private let historyStore: LoginHistoryStore
    private let sessionList: SessionListing
    private let clock: Clock
    private var inFlight: Task<Void, Error>?

    init(source: LiveStateSource, client: UsageClient, cache: UsageCache, history: LoginHistoryStore,
         sessions: SessionListing, clock: Clock) throws {
        self.source = source
        self.client = client
        self.cache = cache
        self.historyStore = history
        self.sessionList = sessions
        self.clock = clock
        usage = try cache.load()
        self.history = try history.load()
    }

    var isRefreshing: Bool { inFlight != nil }

    /// When the current owner became live through a change made outside the
    /// app, if it did.
    var externalChange: Date? {
        LoginHistory.externalChange(in: history, ownerId: live?.ownerId)
    }

    /// Menu open and "Refresh usage": reads the live owner, records a change
    /// the app didn't make, recomputes the running sessions, then fetches
    /// usage for each account with a token, one at a time, updating `usage`
    /// after each. A refresh already running is joined, not repeated.
    func refresh(accountIds: [String]) -> Task<Void, Error> {
        if let inFlight { return inFlight }
        fetching = Set(accountIds)  // Spinners from the first frame.
        let task = Task { try await self.run(accountIds) }
        inFlight = task
        return task
    }

    /// The owner only (no usage, no sessions), after an operation the user
    /// clicked or at launch. `expecting`: the source to record if the owner
    /// changed (the app's own switch or Add account).
    func reloadLive(expecting: LoginChange.Source?) async throws {
        try apply(try await source.liveState(), expecting: expecting)
    }

    private func run(_ accountIds: [String]) async throws {
        defer {
            inFlight = nil
            fetching = []
        }
        let state = try await source.liveState()
        try apply(state, expecting: nil)
        sessions = RunningSessions.compute(sessions: sessionList.liveSessions(), history: history,
                                           liveOwnerId: state.ownerId, savedExpiry: state.savedExpiry, now: clock.now())

        let now = clock.now()
        let requests = accountIds.filter { state.tokens[$0].map { !$0.isExpired(at: now) } ?? false }
        fetching = Set(requests)
        var updated = usage.filter { accountIds.contains($0.key) }
        for id in accountIds {
            guard let token = state.tokens[id] else { continue }
            let result = try await client.fetch(token)
            fetching.remove(id)
            updated[id] = (updated[id] ?? AccountUsage()).applying(result)
            usage = updated
            try cache.save(updated)
            if case .rateLimited = result {
                // Stop this round; the next menu open tries again.
                log.notice("Usage rate limited; skipping the remaining accounts this time")
                break
            }
        }
        usage = updated
        try cache.save(updated)
    }

    /// Records the owner change, if any. An unproven owner records nothing.
    private func apply(_ state: LiveState, expecting: LoginChange.Source?) throws {
        live = state
        guard state.isProven else { return }
        let owner = state.ownerId  // nil: an unsaved organization
        if let last = history.last, last.accountId == owner { return }
        let change = LoginChange(at: state.itemModifiedAt ?? clock.now(), accountId: owner, source: expecting ?? .external)
        history = LoginHistory.appending(change, to: history)
        try historyStore.save(history)
    }
}
