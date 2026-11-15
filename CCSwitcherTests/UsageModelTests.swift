import XCTest

/// Decoding the usage response into rows, labels, severity, the cache and
/// the Ultra rule.
final class UsageModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let session = #"{"kind":"session","group":"session","percent":41,"severity":"normal","resets_at":"2026-11-15T12:40:00.746292+00:00","scope":null,"is_active":true}"#
    private static let weekly = #"{"kind":"weekly_all","group":"weekly","percent":7,"severity":"normal","resets_at":"2026-11-20T10:00:00+00:00","scope":null,"is_active":false}"#
    private static let scoped = #"{"kind":"weekly_scoped","group":"weekly","percent":7,"severity":"normal","resets_at":"2026-11-20T10:00:00+00:00","is_active":false,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}"#

    private func rows(_ json: String) throws -> [UsageLimit] {
        UsageLimit.rows(from: try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8)))
    }

    func testLimitsFixturesInAPIOrder() throws {
        let limits = try rows(#"{"limits":[\#(Self.session),\#(Self.weekly),\#(Self.scoped)],"five_hour":{"utilization":99}}"#)
        XCTAssertEqual(limits.map(\.label), ["Session", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(limits.map(\.percent), [41, 7, 7])
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(limits.map(\.severity), [.normal, .normal, .normal])
        // Fractional seconds with six digits parse.
        XCTAssertNotNil(limits[0].resetsAt)
        XCTAssertNotNil(limits[1].resetsAt)
    }

    func testNoLimitsKeyFallsBackToFiveHourAndSevenDay() throws {
        let limits = try rows(#"{"five_hour":{"utilization":22,"resets_at":"2026-11-15T12:40:00+00:00"},"seven_day":{"utilization":22.4}}"#)
        XCTAssertEqual(limits.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all"])
        XCTAssertEqual(limits.map(\.percent), [22, 22.4])
        XCTAssertNotNil(limits[0].resetsAt)
        XCTAssertNil(limits[1].resetsAt)
    }

    func testMissingPercentAndBadItemsAreSkipped() throws {
        let limits = try rows("""
        {"limits":[{"kind":"session","group":"session","severity":"normal"},
                   {"kind":"weekly_all","percent":"lots"},
                   "garbage",
                   \(Self.weekly)]}
        """)
        XCTAssertEqual(limits.map(\.label), ["Weekly"])
    }

    func testUnknownKindUsesGroupAndUnknownSeverityIsNeutral() throws {
        let limits = try rows("""
        {"limits":[{"kind":"monthly_thing","group":"monthly_pool","percent":50,"severity":"apocalyptic"},
                   {"kind":"daily","percent":60,"severity":"warning","extra":{"nested":true}},
                   {"kind":"weekly_scoped","group":"weekly","percent":70,"severity":"CRITICAL","scope":{"model":null,"surface":"Desktop"}},
                   {"percent":80}]}
        """)
        XCTAssertEqual(limits.map(\.label), ["Monthly pool", "Daily", "Weekly · Desktop", "Limit"])
        XCTAssertEqual(limits.map(\.severity), [.normal, .warning, .critical, .normal])
    }

    func testLabels() {
        XCTAssertEqual(UsageLimit.label(kind: "session", group: "session", scopeName: nil), "Session")
        XCTAssertEqual(UsageLimit.label(kind: "weekly_all", group: "weekly", scopeName: nil), "Weekly")
        XCTAssertEqual(UsageLimit.label(kind: "weekly_scoped", group: "weekly", scopeName: "Fable"), "Weekly · Fable")
        XCTAssertEqual(UsageLimit.label(kind: "weekly_scoped", group: "weekly", scopeName: nil), "Weekly")
        XCTAssertEqual(UsageLimit.label(kind: "new_kind", group: "burst", scopeName: nil), "Burst")
        XCTAssertEqual(UsageLimit.label(kind: "new_kind", group: nil, scopeName: "Opus"), "New kind · Opus")
        XCTAssertEqual(UsageLimit.label(kind: nil, group: nil, scopeName: nil), "Limit")
    }

    func testScopeNameFromStringOrObject() throws {
        let surfaceObject = try rows(#"{"limits":[{"kind":"weekly_scoped","percent":1,"scope":{"surface":{"display_name":"Web"}}}]}"#)
        XCTAssertEqual(surfaceObject.first?.label, "Weekly · Web")
        let modelId = try rows(#"{"limits":[{"kind":"weekly_scoped","percent":1,"scope":{"model":{"id":"claude-x","display_name":null}}}]}"#)
        XCTAssertEqual(modelId.first?.label, "Weekly · claude-x")
    }

    func testNotAnObjectFails() {
        XCTAssertThrowsError(try rows("[1]"))
    }

    // MARK: - Cache

    private func defaults() -> UserDefaults {
        let name = "ccswitcher-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCacheRoundTrips() throws {
        let cache = UsageCache(defaults: defaults())
        let usage = ["a": AccountUsage(snapshot: UsageSnapshot(limits: try rows(#"{"limits":[\#(Self.session),\#(Self.scoped)]}"#),
                                                               fetchedAt: now), tokenExpired: true),
                     "b": AccountUsage()]
        try cache.save(usage)
        XCTAssertEqual(try cache.load(), usage)
    }

    func testOldCacheIsMigratedAndRemoved() throws {
        let defaults = defaults()
        defaults.set(Data(#"{"a":{"snapshot":{"fiveHour":42,"sevenDay":63,"fetchedAt":800000000},"tokenExpired":true}}"#.utf8),
                     forKey: UsageCache.legacyKey)
        let loaded = try UsageCache(defaults: defaults).load()
        XCTAssertEqual(loaded["a"]?.snapshot?.limits.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(loaded["a"]?.snapshot?.limits.map(\.percent), [42, 63])
        XCTAssertEqual(loaded["a"]?.tokenExpired, true)
        XCTAssertNil(defaults.data(forKey: UsageCache.legacyKey))
        XCTAssertEqual(try UsageCache(defaults: defaults).load(), loaded)
    }

    func testDamagedCachesAreDropped() throws {
        let defaults = defaults()
        defaults.set(Data("nope".utf8), forKey: UsageCache.legacyKey)
        XCTAssertEqual(try UsageCache(defaults: defaults).load(), [:])
        XCTAssertNil(defaults.data(forKey: UsageCache.legacyKey))
        defaults.set(Data("nope".utf8), forKey: UsageCache.key)
        XCTAssertEqual(try UsageCache(defaults: defaults).load(), [:])
    }

    func testSavedAccountsWithoutTheTierStillDecode() throws {
        let old = Data(#"[{"id":"1","label":"Team","email":"me@x.com","orgUuid":"org-team","plan":"team"}]"#.utf8)
        let accounts = try JSONDecoder().decode([SavedAccount].self, from: old)
        XCTAssertEqual(accounts.first?.plan, "team")
        XCTAssertNil(accounts.first?.rateLimitTier)
    }

    // MARK: - Ultra

    func testUltraHidesSessionOnly() throws {
        var account = Fixture.team
        account.plan = "max"
        account.rateLimitTier = "default_claude_max_20x"
        let limits = try rows(#"{"limits":[\#(Self.session),\#(Self.weekly),\#(Self.scoped)]}"#)
        XCTAssertEqual(PlanRule.visibleLimits(limits, for: account).map(\.label), ["Weekly", "Weekly · Fable"])

        // The five_hour fallback is a Session row too.
        let fallback = try rows(#"{"five_hour":{"utilization":22},"seven_day":{"utilization":22}}"#)
        XCTAssertEqual(PlanRule.visibleLimits(fallback, for: account).map(\.label), ["Weekly"])
    }

    func testPlanRule() {
        XCTAssertFalse(PlanRule.showsSessionLimit(plan: ["max", "default_claude_max_20x"]))
        XCTAssertFalse(PlanRule.showsSessionLimit(plan: [nil, "DEFAULT_CLAUDE_MAX_20X"]))
        XCTAssertFalse(PlanRule.showsSessionLimit(plan: ["Ultra", nil]))
        XCTAssertTrue(PlanRule.showsSessionLimit(plan: ["max", "default_claude_max_5x"]))
        XCTAssertTrue(PlanRule.showsSessionLimit(plan: ["team", nil]))
        XCTAssertTrue(PlanRule.showsSessionLimit(plan: [nil, nil]))
        XCTAssertTrue(PlanRule.showsSessionLimit(plan: ["something_new"]))
        XCTAssertTrue(PlanRule.showsSessionLimit(for: Fixture.team))
    }

    // MARK: - Presentation

    func testStaleWhenExpiredOldOrUnverified() throws {
        let snapshot = UsageSnapshot(limits: try rows(#"{"limits":[\#(Self.weekly)]}"#), fetchedAt: now.addingTimeInterval(-60))
        let fresh = UsagePresentation.make(usage: AccountUsage(snapshot: snapshot), account: Fixture.team, fetching: false,
                                           ownerUnverified: false, now: now)
        XCTAssertFalse(fresh.stale)
        XCTAssertNil(fresh.asOf)

        let expired = UsagePresentation.make(usage: AccountUsage(snapshot: snapshot, tokenExpired: true), account: Fixture.team,
                                             fetching: false, ownerUnverified: false, now: now)
        XCTAssertTrue(expired.stale)
        XCTAssertEqual(expired.asOf, snapshot.fetchedAt)

        let unverified = UsagePresentation.make(usage: AccountUsage(snapshot: snapshot), account: Fixture.team, fetching: false,
                                                ownerUnverified: true, now: now)
        XCTAssertTrue(unverified.stale)

        let old = UsagePresentation.make(usage: AccountUsage(snapshot: snapshot), account: Fixture.team, fetching: false,
                                         ownerUnverified: false, now: now.addingTimeInterval(3600))
        XCTAssertTrue(old.stale)
        // While a fetch runs, old rows aren't marked stale; they update in place.
        let fetching = UsagePresentation.make(usage: AccountUsage(snapshot: snapshot), account: Fixture.team, fetching: true,
                                              ownerUnverified: false, now: now.addingTimeInterval(3600))
        XCTAssertFalse(fetching.stale)
    }

    func testResetText() {
        XCTAssertEqual(UsagePresentation.resetText(now.addingTimeInterval(2 * 3600 + 10 * 60), now: now), "Resets in 2h 10m")
        XCTAssertEqual(UsagePresentation.resetText(now.addingTimeInterval(45 * 60), now: now), "Resets in 45m")
        XCTAssertEqual(UsagePresentation.resetText(now.addingTimeInterval(-1), now: now), "Resets soon")
        XCTAssertNil(UsagePresentation.resetText(nil, now: now))
        XCTAssertTrue(UsagePresentation.resetText(now.addingTimeInterval(3 * 86400), now: now)?.hasPrefix("Resets ") == true)
    }
}
