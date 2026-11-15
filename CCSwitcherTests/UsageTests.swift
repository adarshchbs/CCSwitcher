import XCTest

final class FakeHTTP: HTTPGetting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int, body: String = "{}", headers: [String: String] = [:]) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var valid: UsageToken { UsageToken(accessToken: "access", expiresAt: now.addingTimeInterval(3600)) }

    private func client(_ http: FakeHTTP) -> UsageClient {
        UsageClient(http: http, clock: FixedClock(date: now))
    }

    func testExpiredTokenSendsNoRequest() async throws {
        let http = FakeHTTP(status: 200)
        let result = try await client(http).fetch(UsageToken(accessToken: "access", expiresAt: now.addingTimeInterval(-1)))
        XCTAssertEqual(result, .expired)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func test401MarksExpiredAndNeverRefreshes() async throws {
        let http = FakeHTTP(status: 401)
        let result = try await client(http).fetch(valid)
        XCTAssertEqual(result, .expired)
        // Exactly one request, and it is the usage GET: no token endpoint call.
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, UsageClient.url)
        XCTAssertEqual(http.requests.first?.httpMethod, "GET")

        let usage = AccountUsage(snapshot: nil).applying(result)
        XCTAssertTrue(usage.tokenExpired)
    }

    func testRequestShape() async throws {
        let http = FakeHTTP(status: 200, body: """
        {"five_hour":{"utilization":42.4,"resets_at":"2027-01-15T10:00:00.123+00:00"},
         "seven_day":{"utilization":63,"resets_at":"2027-01-20T10:00:00+00:00"},"extra":1}
        """)
        let result = try await client(http).fetch(valid)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.httpBody)

        guard case .fresh(let snapshot) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(snapshot.fiveHour, 42.4)
        XCTAssertEqual(snapshot.sevenDay, 63)
        XCTAssertNotNil(snapshot.fiveHourResetsAt)
        XCTAssertNotNil(snapshot.sevenDayResetsAt)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(AccountUsage(snapshot: snapshot).summary(now: now), "5h 42% · 7d 63%")
    }

    func test429KeepsCachedValues() async throws {
        let http = FakeHTTP(status: 429, headers: ["Retry-After": "120"])
        let result = try await client(http).fetch(valid)
        XCTAssertEqual(result, .rateLimited(retryAfter: 120))

        let cached = AccountUsage(snapshot: UsageSnapshot(fiveHour: 3, fiveHourResetsAt: nil, sevenDay: 18,
                                                          sevenDayResetsAt: nil, fetchedAt: now))
        XCTAssertEqual(cached.applying(result), cached)
    }

    func testSummaryShowsAgeAndExpiry() {
        let fetched = now.addingTimeInterval(-3600)
        let snapshot = UsageSnapshot(fiveHour: 3, fiveHourResetsAt: nil, sevenDay: 18, sevenDayResetsAt: nil, fetchedAt: fetched)
        let time = fetched.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(AccountUsage(snapshot: snapshot).summary(now: now), "5h 3% · 7d 18%  (as of \(time))")
        XCTAssertEqual(AccountUsage(snapshot: snapshot, tokenExpired: true).summary(now: now),
                       "5h 3% · 7d 18%  (as of \(time) · refreshes after switching)")
        XCTAssertEqual(AccountUsage(snapshot: nil).summary(now: now), "usage unavailable")
    }

    func testUsageTokensUseLiveItemForActiveAccountAndStoredForOthers() async throws {
        let item = FakeItem(Fixture.envelope(Fixture.oauth("team-live")))
        let store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        let switcher = Switcher(item: item, store: store, config: FakeConfig(Fixture.profile(org: "org-team")),
                                accounts: FakeAccounts([Fixture.team, Fixture.personal]), sessions: FakeSessions())

        let tokens = try await switcher.usageTokens()
        XCTAssertEqual(tokens[Fixture.team.id]?.accessToken, "team-live-access")
        XCTAssertEqual(tokens[Fixture.personal.id]?.accessToken, "personal-access")
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)

        store.items[Fixture.personal.id] = nil
        let partial = try await switcher.usageTokens()
        XCTAssertNil(partial[Fixture.personal.id])
        XCTAssertNotNil(partial[Fixture.team.id])
    }
}
