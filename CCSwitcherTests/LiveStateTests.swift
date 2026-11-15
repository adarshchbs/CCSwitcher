import XCTest

/// Who owns the live token, how usage is attributed, and Fix ~/.claude.json.
/// The scenario from the field: Add account put Personal's token in the
/// Keychain, then a running session rewrote ~/.claude.json back to Team.
final class LiveStateTests: XCTestCase {
    private var item: FakeItem!
    private var store: FakeStore!
    private var config: FakeConfig!
    private var accounts: FakeAccounts!
    private var lookup: FakeLookup!

    override func setUpWithError() throws {
        item = FakeItem(Fixture.envelope(Fixture.oauth("team-live")))
        store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        config = FakeConfig(Fixture.profile(org: "org-team"))
        accounts = FakeAccounts([Fixture.team, Fixture.personal])
        lookup = FakeLookup()
    }

    private func makeSwitcher() -> Switcher {
        Switcher(item: item, store: store, config: config, accounts: accounts, sessions: FakeSessions(),
                 lookup: lookup, clock: FixedClock(date: Fixture.now), journal: FakeJournal(),
                 cli: Fixture.noCLI, login: FakeLoginRunner())
    }

    /// The live token is Personal's (a fresh one the profile endpoint
    /// confirms), while ~/.claude.json names Team.
    private func personalLiveButFileSaysTeam() {
        item.data = Fixture.envelope(Fixture.oauth("personal-new"))
    }

    func testActiveFollowsTheTokenOwnerWhenTheFileDisagrees() async throws {
        personalLiveButFileSaysTeam()
        let state = try await makeSwitcher().liveState()
        XCTAssertEqual(state.owner, .account(Fixture.personal.id))
        XCTAssertEqual(state.activeId, Fixture.personal.id)
        XCTAssertEqual(state.fileAccountId, Fixture.team.id)
        XCTAssertTrue(state.fileMismatch)
        XCTAssertEqual(state.fixableOwnerId, Fixture.personal.id)
        XCTAssertEqual(lookup.tokens, ["personal-new-access"])
    }

    func testRefreshTokenMatchNeedsNoRequest() async throws {
        item.data = Fixture.envelope(Fixture.oauth("personal"))
        let state = try await makeSwitcher().liveState()
        XCTAssertEqual(state.owner, .account(Fixture.personal.id))
        XCTAssertTrue(lookup.tokens.isEmpty)
    }

    func testUsageIsAttributedByOwner() async throws {
        personalLiveButFileSaysTeam()
        let tokens = try await makeSwitcher().liveState().tokens
        // Personal gets the live token; Team gets its own saved one, never
        // the live token, so the two rows can't show the same numbers.
        XCTAssertEqual(tokens[Fixture.personal.id]?.accessToken, "personal-new-access")
        XCTAssertEqual(tokens[Fixture.team.id]?.accessToken, "team-old-access")
    }

    func testUnprovenOwnerFallsBackToTheFileUnverifiedWithNoTokenForIt() async throws {
        item.data = Fixture.envelope(Fixture.oauth("mystery"))
        lookup.result = .failed("offline")
        let state = try await makeSwitcher().liveState()
        guard case .unproven = state.owner else { return XCTFail("\(state.owner)") }
        XCTAssertEqual(state.activeId, Fixture.team.id)
        XCTAssertFalse(state.isProven)
        XCTAssertFalse(state.fileMismatch)
        XCTAssertNil(state.fixableOwnerId)
        // The live token might be anyone's: nobody gets it, and Team (the
        // checked row) gets nothing, so its cached rows show as stale.
        XCTAssertNil(state.tokens[Fixture.team.id])
        XCTAssertEqual(state.tokens[Fixture.personal.id]?.accessToken, "personal-access")
    }

    func testUnsavedOrganizationGetsNoAccountAndNoFix() async throws {
        item.data = Fixture.envelope(Fixture.oauth("other"))
        lookup.prefixes = ["other": "org-other"]
        let state = try await makeSwitcher().liveState()
        XCTAssertEqual(state.owner, .unsavedOrg(uuid: "org-other", name: "ORG-OTHER"))
        XCTAssertNil(state.activeId)
        XCTAssertTrue(state.fileMismatch)
        XCTAssertNil(state.fixableOwnerId)
        XCTAssertEqual(state.tokens[Fixture.team.id]?.accessToken, "team-old-access")
        XCTAssertEqual(state.tokens[Fixture.personal.id]?.accessToken, "personal-access")
    }

    func testModificationDateAndSavedExpiryAreReported() async throws {
        item.modifiedAt = Fixture.now.addingTimeInterval(-60)
        let state = try await makeSwitcher().liveState()
        XCTAssertEqual(state.itemModifiedAt, Fixture.now.addingTimeInterval(-60))
        XCTAssertEqual(state.savedExpiry[Fixture.team.id], Date(timeIntervalSince1970: 4_102_444_800))
    }

    // MARK: - Fix ~/.claude.json

    func testFixWritesTheOwnersProfileOnlyWhenCalled() async throws {
        personalLiveButFileSaysTeam()
        let switcher = makeSwitcher()
        _ = try await switcher.liveState()
        _ = try await switcher.liveState()
        XCTAssertEqual(config.writes, 0, "detection never writes")

        let outcome = try await switcher.fixClaudeJSON(ownerId: Fixture.personal.id)
        XCTAssertEqual(outcome, .fixed(Fixture.personal))
        XCTAssertEqual(config.writes, 1)
        XCTAssertEqual(config.profile?.organizationUuid, "org-personal")
        XCTAssertTrue(item.writes.isEmpty, "the Keychain item is never touched")
        XCTAssertEqual(store.writes, 0)

        let after = try await switcher.liveState()
        XCTAssertFalse(after.fileMismatch)
        let again = try await switcher.fixClaudeJSON(ownerId: Fixture.personal.id)
        XCTAssertEqual(again, .alreadyConsistent)
        XCTAssertEqual(config.writes, 1)
    }

    func testNoFixWhenTheOwnerIsUnproven() async throws {
        item.data = Fixture.envelope(Fixture.oauth("mystery"))
        lookup.result = .failed("offline")
        let state = try await makeSwitcher().liveState()
        XCTAssertNil(state.fixableOwnerId)
        // Even called directly, the strict check refuses.
        do {
            _ = try await makeSwitcher().fixClaudeJSON(ownerId: Fixture.personal.id)
            XCTFail("expected a refusal")
        } catch let error as SwitchError {
            guard case .ownershipUnverified = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(config.writes, 0)
    }

    func testFixRefusesAnotherAccountsToken() async throws {
        personalLiveButFileSaysTeam()
        // Asking to fix for an account that doesn't own the token.
        lookup.prefixes = ["personal": "org-personal"]
        accounts.accounts.append(SavedAccount(id: "third", label: "Third", email: "me@x.com", orgUuid: "org-third"))
        do {
            _ = try await makeSwitcher().fixClaudeJSON(ownerId: "third")
            XCTFail("expected a refusal")
        } catch let error as SwitchError {
            XCTAssertEqual(error, .liveLoginMismatch)
        }
        XCTAssertEqual(config.writes, 0)
    }

    // MARK: - Rate-limit tier

    func testProfileCheckBackfillsTheTier() async throws {
        lookup.result = .organization(uuid: "org-team", name: "Acme", rateLimitTier: "default_claude_max_20x")
        _ = try await makeSwitcher().liveState()
        XCTAssertEqual(accounts.accounts.first { $0.id == Fixture.team.id }?.rateLimitTier, "default_claude_max_20x")
        XCTAssertNil(accounts.accounts.first { $0.id == Fixture.personal.id }?.rateLimitTier)
    }

    func testSaveRecordsTheTierFromTheProfile() async throws {
        var fields = Fixture.profile(org: "org-team").fields
        fields["organizationRateLimitTier"] = AnyCodable("default_claude_max_20x")
        config.profile = OAuthProfile(fields: fields)
        let outcome = try await makeSwitcher().saveCurrentLogin { _ in nil }
        guard case .updated(let account) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(account.rateLimitTier, "default_claude_max_20x")
        XCTAssertFalse(PlanRule.showsSessionLimit(for: account))
    }
}
