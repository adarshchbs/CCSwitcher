import XCTest

/// A one-shot latch for ordering async steps in tests. No timers.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Returns a fixed `LiveState`, counting calls. With `hold`, each call
/// signals `entered` and waits for `hold` to open.
final class FakeLiveSource: LiveStateSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: LiveState
    private var _calls = 0
    var hold: Latch?
    let entered = Latch()

    init(_ state: LiveState) { _state = state }

    var calls: Int { lock.withLock { _calls } }
    var state: LiveState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    func liveState() async throws -> LiveState {
        lock.withLock { _calls += 1 }
        entered.open()
        if let hold { await hold.wait() }
        return state
    }
}

final class FakeSessionList: SessionListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var sessions: [LiveSession]

    init(_ sessions: [LiveSession] = []) { self.sessions = sessions }

    var calls: Int { lock.withLock { _calls } }

    func liveSessions() -> [LiveSession] {
        lock.withLock {
            _calls += 1
            return sessions
        }
    }
}

final class MemoryHistory: LoginHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    var history: [LoginChange]
    var saves = 0

    init(_ history: [LoginChange] = []) { self.history = history }

    func load() throws -> [LoginChange] { lock.withLock { history } }
    func save(_ history: [LoginChange]) throws { lock.withLock { saves += 1; self.history = history } }
}

final class MutableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@MainActor
final class AccountStatusTests: XCTestCase {
    private let now = Fixture.now
    private let body = #"{"limits":[{"kind":"session","percent":41,"severity":"normal"},{"kind":"weekly_all","percent":7,"severity":"warning"}]}"#

    private var valid: UsageToken { UsageToken(accessToken: "live", expiresAt: now.addingTimeInterval(3600)) }
    private var expired: UsageToken { UsageToken(accessToken: "old", expiresAt: now.addingTimeInterval(-1)) }
    private var ids: [String] { [Fixture.team.id, Fixture.personal.id] }

    private func state(owner: TokenOwner = .account(Fixture.team.id), tokens: [String: UsageToken]? = nil,
                       modifiedAt: Date? = nil) -> LiveState {
        LiveState(owner: owner, ownerOrgUuid: "org-team", fileAccountId: Fixture.team.id, fileOrgUuid: "org-team",
                  fileOrgName: nil, itemModifiedAt: modifiedAt,
                  tokens: tokens ?? [Fixture.team.id: valid, Fixture.personal.id: valid], savedExpiry: [:])
    }

    private func defaults() -> UserDefaults {
        let name = "ccswitcher-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeStatus(_ source: FakeLiveSource, http: FakeHTTP, sessions: FakeSessionList = FakeSessionList(),
                            history: MemoryHistory = MemoryHistory(), cache: UsageCache? = nil,
                            clock: Clock? = nil) throws -> AccountStatus {
        let clock = clock ?? FixedClock(date: now)
        return try AccountStatus(source: source, client: UsageClient(http: http, clock: clock),
                                 cache: cache ?? UsageCache(defaults: defaults()), history: history,
                                 sessions: sessions, clock: clock)
    }

    // MARK: - Fetch triggers

    func testMenuOpenFetchesOncePerAccountWithAnUnexpiredToken() async throws {
        let http = FakeHTTP(status: 200, body: body)
        let source = FakeLiveSource(state(tokens: [Fixture.team.id: valid, Fixture.personal.id: expired]))
        let status = try makeStatus(source, http: http)

        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(http.requests.count, 1, "the expired token sends nothing")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer live")
        XCTAssertEqual(status.usage[Fixture.team.id]?.snapshot?.limits.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(status.usage[Fixture.team.id]?.snapshot?.limits.last?.severity, .warning)
        XCTAssertEqual(status.usage[Fixture.personal.id]?.tokenExpired, true)
        XCTAssertTrue(status.fetching.isEmpty)
        XCTAssertFalse(status.isRefreshing)
    }

    func testOpeningAgainWhileInFlightJoins() async throws {
        let http = FakeHTTP(status: 200, body: body)
        let source = FakeLiveSource(state())
        let hold = Latch()
        source.hold = hold
        let status = try makeStatus(source, http: http)

        let first = status.refresh(accountIds: ids)
        // Spinners show right away, before anything returns.
        XCTAssertEqual(status.fetching, Set(ids))
        await source.entered.wait()
        let second = status.refresh(accountIds: ids)
        XCTAssertEqual(first, second)
        hold.open()
        try await first.value
        try await second.value
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(http.requests.count, 2, "one request per account, not two")

        // A later open is a new refresh: every open fetches, no cooldown.
        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(http.requests.count, 4)
    }

    func testRefreshClickFetches() async throws {
        let http = FakeHTTP(status: 200, body: body)
        let source = FakeLiveSource(state())
        let status = try makeStatus(source, http: http)
        // "Refresh usage" calls the same entry point as a menu open.
        try await status.refresh(accountIds: ids).value
        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(http.requests.count, 4)
    }

    func testNothingElseFetchesOrRecomputes() async throws {
        let http = FakeHTTP(status: 200, body: body)
        let source = FakeLiveSource(state())
        let sessions = FakeSessionList([LiveSession(pid: 1, detail: "", startedAt: now)])
        let clock = MutableClock(now)
        let status = try makeStatus(source, http: http, sessions: sessions, clock: clock)
        for _ in 0..<20 { await Task.yield() }
        clock.advance(86_400)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(sessions.calls, 0)
        XCTAssertTrue(http.requests.isEmpty)

        // After an operation, only the owner is read: no usage, no sessions.
        try await status.reloadLive(expecting: .switch)
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(sessions.calls, 0)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testExpiredTokenSendsNothingAndCachedRowsAreStale() async throws {
        let cache = UsageCache(defaults: defaults())
        let cached = UsageSnapshot(limits: [UsageLimit(kind: "weekly_all", label: "Weekly", percent: 18, severity: .normal,
                                                       resetsAt: nil)], fetchedAt: now.addingTimeInterval(-60))
        try cache.save([Fixture.personal.id: AccountUsage(snapshot: cached)])
        let http = FakeHTTP(status: 200, body: body)
        let source = FakeLiveSource(state(tokens: [Fixture.personal.id: expired]))
        let status = try makeStatus(source, http: http, cache: cache)

        try await status.refresh(accountIds: ids).value
        XCTAssertTrue(http.requests.isEmpty)
        let usage = try XCTUnwrap(status.usage[Fixture.personal.id])
        XCTAssertEqual(usage.snapshot, cached)
        let shown = UsagePresentation.make(usage: usage, account: Fixture.personal, fetching: false, ownerUnverified: false, now: now)
        XCTAssertTrue(shown.stale)
        XCTAssertEqual(shown.asOf, cached.fetchedAt)
        XCTAssertEqual(try cache.load()[Fixture.personal.id]?.tokenExpired, true)
    }

    func test401MarksExpired() async throws {
        let status = try makeStatus(FakeLiveSource(state()), http: FakeHTTP(status: 401))
        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(status.usage[Fixture.team.id]?.tokenExpired, true)
    }

    // MARK: - History

    func testExternalChangeIsLoggedWithTheKeychainDate() async throws {
        let t0 = now.addingTimeInterval(-7200)
        let mdat = now.addingTimeInterval(-600)
        let history = MemoryHistory([LoginChange(at: t0, accountId: Fixture.personal.id, source: .switch)])
        let source = FakeLiveSource(state(owner: .account(Fixture.team.id), modifiedAt: mdat))
        let status = try makeStatus(source, http: FakeHTTP(status: 200, body: body), history: history)

        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(history.history.last, LoginChange(at: mdat, accountId: Fixture.team.id, source: .external))
        XCTAssertEqual(status.externalChange, mdat)

        // Same owner again: nothing new.
        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(history.history.count, 2)
    }

    func testTheAppsOwnChangeIsNotExternal() async throws {
        let history = MemoryHistory([LoginChange(at: now.addingTimeInterval(-7200), accountId: Fixture.personal.id, source: .switch)])
        let source = FakeLiveSource(state(owner: .account(Fixture.team.id), modifiedAt: now))
        let status = try makeStatus(source, http: FakeHTTP(status: 200, body: body), history: history)
        try await status.reloadLive(expecting: .switch)
        XCTAssertEqual(history.history.last, LoginChange(at: now, accountId: Fixture.team.id, source: .switch))
        XCTAssertNil(status.externalChange)
    }

    func testUnprovenOwnerRecordsNothing() async throws {
        let history = MemoryHistory()
        let source = FakeLiveSource(state(owner: .unproven("offline")))
        let status = try makeStatus(source, http: FakeHTTP(status: 200, body: body), history: history)
        try await status.refresh(accountIds: ids).value
        XCTAssertTrue(history.history.isEmpty)
        XCTAssertEqual(history.saves, 0)
    }

    func testHistoryKeepsTheLastTwenty() {
        var history: [LoginChange] = []
        for index in 0..<30 {
            history = LoginHistory.appending(LoginChange(at: now.addingTimeInterval(Double(index)), accountId: "\(index)",
                                                         source: .external), to: history)
        }
        XCTAssertEqual(history.count, LoginHistory.limit)
        XCTAssertEqual(history.first?.accountId, "10")
        XCTAssertEqual(history.last?.accountId, "29")
    }

    func testRefreshRecomputesSessions() async throws {
        let history = MemoryHistory([LoginChange(at: now.addingTimeInterval(-7200), accountId: Fixture.team.id, source: .switch)])
        let sessions = FakeSessionList([LiveSession(pid: 1, detail: "", startedAt: now.addingTimeInterval(-60))])
        let status = try makeStatus(FakeLiveSource(state()), http: FakeHTTP(status: 200, body: body), sessions: sessions,
                                    history: history)
        try await status.refresh(accountIds: ids).value
        XCTAssertEqual(sessions.calls, 1)
        XCTAssertEqual(status.sessions.byAccount, [Fixture.team.id: 1])
    }
}

/// Mapping running sessions to the account live when they started, and the
/// warning rows.
final class RunningSessionsTests: XCTestCase {
    private let now = Fixture.now
    private var t0: Date { now.addingTimeInterval(-10_000) }
    private var switchedAt: Date { now.addingTimeInterval(-1000) }

    private var history: [LoginChange] {
        [LoginChange(at: t0, accountId: Fixture.team.id, source: .switch),
         LoginChange(at: switchedAt, accountId: Fixture.personal.id, source: .switch)]
    }

    private func session(_ pid: Int32, _ offset: TimeInterval?) -> LiveSession {
        LiveSession(pid: pid, detail: "", startedAt: offset.map { now.addingTimeInterval($0) })
    }

    func testSessionsBeforeAndAfterASwitch() {
        let result = RunningSessions.compute(
            sessions: [session(1, -5000), session(2, -4000), session(3, -10), session(4, -20_000), session(5, nil)],
            history: history, liveOwnerId: Fixture.personal.id, savedExpiry: [:], now: now)
        XCTAssertEqual(result.byAccount, [Fixture.team.id: 2, Fixture.personal.id: 1])
        XCTAssertEqual(result.unknown, 2, "before the first entry, or no start time")
        XCTAssertEqual(result.total, 5)
        XCTAssertEqual(LoginHistory.account(at: switchedAt, in: history), .account(Fixture.personal.id))
    }

    func testWriteBackEstimateUsesTheSavedExpiry() {
        let expiry = now.addingTimeInterval(3 * 3600)
        let result = RunningSessions.compute(sessions: [session(1, -5000)], history: history, liveOwnerId: Fixture.personal.id,
                                             savedExpiry: [Fixture.team.id: expiry], now: now)
        XCTAssertEqual(result.warnings, [RunningSessions.Warning(accountId: Fixture.team.id, count: 1, liveSince: switchedAt,
                                                                 writeBackAround: expiry)])
        let past = RunningSessions.compute(sessions: [session(1, -5000)], history: history, liveOwnerId: Fixture.personal.id,
                                           savedExpiry: [Fixture.team.id: now.addingTimeInterval(-1)], now: now)
        XCTAssertNil(past.warnings.first?.writeBackAround)
    }

    func testUnknownOwnerGivesNoWarnings() {
        let result = RunningSessions.compute(sessions: [session(1, -5000)], history: history, liveOwnerId: nil,
                                             savedExpiry: [:], now: now)
        XCTAssertEqual(result.byAccount, [Fixture.team.id: 1])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    private func input(live: LiveState?, sessions: RunningSessions, externalChange: Date? = nil) -> MenuInput {
        MenuInput(accounts: [Fixture.team, Fixture.personal], live: live, usage: [:], fetching: [], sessions: sessions,
                  externalChange: externalChange, signingIn: false, unfinished: false, notice: nil, now: now)
    }

    private func live(owner: TokenOwner, file: String? = Fixture.personal.id, fileOrg: String? = "org-personal") -> LiveState {
        let ownerOrg: String? = switch owner {
        case .account(let id): id == Fixture.team.id ? "org-team" : "org-personal"
        case .unsavedOrg(let uuid, _): uuid
        case .unproven: nil
        }
        return LiveState(owner: owner, ownerOrgUuid: ownerOrg, fileAccountId: file, fileOrgUuid: fileOrg, fileOrgName: nil,
                         itemModifiedAt: nil, tokens: [:], savedExpiry: [:])
    }

    private func notes(_ rows: [MenuRow]) -> [String] {
        rows.compactMap { if case .note(let line) = $0 { line.text } else { nil } }
    }

    func testWarningOnlyWhenSessionsAreOnANonLiveAccount() {
        let onLive = RunningSessions.compute(sessions: [session(1, -10)], history: history, liveOwnerId: Fixture.personal.id,
                                             savedExpiry: [:], now: now)
        XCTAssertTrue(MenuRows.sessionWarnings(input(live: live(owner: .account(Fixture.personal.id)), sessions: onLive)).isEmpty)

        let expiry = now.addingTimeInterval(3 * 3600)
        let onOld = RunningSessions.compute(sessions: [session(1, -5000), session(2, -4000), session(3, -10)], history: history,
                                            liveOwnerId: Fixture.personal.id, savedExpiry: [Fixture.team.id: expiry], now: now)
        let rows = MenuRows.sessionWarnings(input(live: live(owner: .account(Fixture.personal.id)), sessions: onOld))
        XCTAssertEqual(notes(rows), [
            "⚠︎ 2 Claude sessions started before \(MenuRows.time(switchedAt)) may still be using Team. "
                + "Restart them to be sure they use Personal.\n"
                + "They may switch the login back to Team when their token refreshes (around \(MenuRows.time(expiry))).",
        ])
    }

    func testAccountRowsShowSessionsTagsAndExternalChange() {
        let sessions = RunningSessions.compute(
            sessions: [session(1, -5000), session(2, -10), session(3, -10), session(4, -20_000)],
            history: history, liveOwnerId: Fixture.personal.id, savedExpiry: [:], now: now)
        let changed = now.addingTimeInterval(-60)
        let rows = MenuRows.rows(input(live: live(owner: .account(Fixture.personal.id)), sessions: sessions, externalChange: changed))
        let accounts = rows.compactMap { if case .account(let line) = $0 { line } else { nil } }
        XCTAssertEqual(accounts.map(\.checked), [false, true])
        XCTAssertEqual(accounts.map(\.tag), [nil, "new sessions"])
        let texts = notes(rows)
        XCTAssertTrue(texts.contains("1 running session started before the switch"))
        XCTAssertTrue(texts.contains("2 running sessions"))
        XCTAssertTrue(texts.contains("Changed outside CCSwitcher at \(MenuRows.time(changed))"))
        XCTAssertTrue(texts.contains("1 running session: account unknown"))
    }

    func testMismatchOffersTheFixOnlyForAProvenSavedOwner() {
        let proven = MenuRows.rows(input(live: live(owner: .account(Fixture.personal.id), file: Fixture.team.id, fileOrg: "org-team"),
                                         sessions: RunningSessions()))
        XCTAssertTrue(notes(proven).contains(
            "⚠︎ ~/.claude.json shows Team, but the live login is Personal. A running Claude session probably rewrote it."))
        XCTAssertTrue(notes(proven).contains("Running Claude sessions may undo this until restarted."))
        XCTAssertTrue(proven.contains(.action(ActionLine(action: .fixClaudeJSON, title: "Fix ~/.claude.json"))))

        let unproven = MenuRows.rows(input(live: live(owner: .unproven("offline"), file: Fixture.team.id, fileOrg: "org-team"),
                                           sessions: RunningSessions()))
        XCTAssertFalse(unproven.contains { $0.key == "x:fixClaudeJSON" })
        let unverified = unproven.compactMap { if case .account(let line) = $0, line.checked { line } else { nil } }
        XCTAssertEqual(unverified.map(\.tag), ["unverified"])

        let unsaved = MenuRows.rows(input(live: live(owner: .unsavedOrg(uuid: "org-x", name: "X"), file: Fixture.team.id,
                                                     fileOrg: "org-team"), sessions: RunningSessions()))
        XCTAssertFalse(unsaved.contains { $0.key == "x:fixClaudeJSON" })
        XCTAssertTrue(notes(unsaved).contains { $0.contains("the live login is X (not saved)") })
    }

    func testUltraAccountShowsNoSessionRow() {
        var ultra = Fixture.team
        ultra.rateLimitTier = "default_claude_max_20x"
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: "session", label: "Session", percent: 22, severity: .normal, resetsAt: nil),
            UsageLimit(kind: "weekly_all", label: "Weekly", percent: 22, severity: .normal, resetsAt: nil),
        ], fetchedAt: now)
        var menu = input(live: live(owner: .account(Fixture.team.id), file: Fixture.team.id, fileOrg: "org-team"),
                         sessions: RunningSessions())
        menu.accounts = [ultra, Fixture.personal]
        menu.usage = [ultra.id: AccountUsage(snapshot: snapshot), Fixture.personal.id: AccountUsage(snapshot: snapshot)]
        let usage = MenuRows.rows(menu).compactMap { if case .usage(let line) = $0 { line.key + "=" + line.label } else { nil } }
        XCTAssertEqual(usage, ["\(ultra.id):0=Weekly", "\(Fixture.personal.id):0=Session", "\(Fixture.personal.id):1=Weekly"])
    }

    func testUsageLineShowsWhatIsLeft() {
        func line(_ used: Double) -> UsageLine {
            UsageLine(key: "k", label: "Weekly", percent: used, severity: .normal, stale: false, tooltip: nil)
        }
        XCTAssertEqual(line(7).remaining, 93)
        XCTAssertEqual(line(0).remaining, 100)
        XCTAssertEqual(line(100).remaining, 0)
        XCTAssertEqual(line(130).remaining, 0)
        XCTAssertEqual(line(-5).remaining, 100)
    }

    func testBlocksGroupEachAccountsRowsIntoItsCard() {
        func account(_ id: String) -> MenuRow {
            .account(AccountLine(id: id, label: id, checked: false, tag: nil, trailing: nil, fetching: false, tooltip: nil))
        }
        func usage(_ key: String) -> MenuRow {
            .usage(UsageLine(key: key, label: "Weekly", percent: 10, severity: .normal, stale: false, tooltip: nil))
        }
        func note(_ key: String, indented: Bool) -> MenuRow {
            .note(NoteLine(key: key, text: key, indented: indented, style: .secondary))
        }
        let rows: [MenuRow] = [
            .header("Claude Account"),
            account("a"), note("a:sessions", indented: true), usage("a:0"),
            account("b"), usage("b:0"), note("b:placeholder", indented: true),
            note("warning", indented: false),
            .separator("accounts"),
            .action(ActionLine(action: .fixClaudeJSON, title: "Fix ~/.claude.json")),
            note("mismatch:undo", indented: true),
        ]
        let blocks = MenuRows.blocks(rows)
        XCTAssertEqual(blocks.map(\.id), ["h:Claude Account", "card:a", "card:b", "n:warning:warning", "s:accounts",
                                          "x:fixClaudeJSON", "n:mismatch:undo:mismatch:undo"])
        guard case .card(let first) = blocks[1], case .card(let second) = blocks[2] else { return XCTFail("no cards") }
        XCTAssertEqual(first.rows.map(\.key), ["n:a:sessions:a:sessions", "u:a:0"])
        XCTAssertEqual(second.rows.map(\.key), ["u:b:0", "n:b:placeholder:b:placeholder"])
        XCTAssertEqual([first.index, second.index], [0, 1])
    }
}
