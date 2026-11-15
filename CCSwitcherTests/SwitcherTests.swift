import XCTest

/// The switch state machine, driven with fakes. Team is live; the tests switch
/// to Personal, which has the same email address and a different org.
final class SwitcherTests: XCTestCase {
    private var item: FakeItem!
    private var store: FakeStore!
    private var config: FakeConfig!
    private var accounts: FakeAccounts!
    private var sessions = FakeSessions()
    private var lookup: FakeLookup!
    private var journal: FakeJournal!

    private var liveEnvelope: Data { Fixture.envelope(Fixture.oauth("team-live")) }

    override func setUpWithError() throws {
        item = FakeItem(liveEnvelope)
        store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        config = FakeConfig(Fixture.profile(org: "org-team"))
        accounts = FakeAccounts([Fixture.team, Fixture.personal])
        lookup = FakeLookup()
        journal = FakeJournal()
    }

    private func makeSwitcher() -> Switcher {
        Switcher(item: item, store: store, config: config, accounts: accounts, sessions: sessions,
                 lookup: lookup, clock: FixedClock(date: Fixture.now), journal: journal,
                 cli: Fixture.noCLI, login: FakeLoginRunner())
    }

    private func switchToPersonal(confirm: @escaping @Sendable ([LiveSession]) async -> Bool = { _ in true }) async throws -> SwitchOutcome {
        try await makeSwitcher().switchTo(Fixture.personal.id, confirm: confirm)
    }

    private func assertThrows(_ expected: SwitchError, _ body: () async throws -> some Any,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SwitchError, expected, file: file, line: line)
        }
    }

    private func assertThrowsCase(_ matches: (SwitchError) -> Bool, _ body: () async throws -> some Any,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch let error as SwitchError {
            XCTAssertTrue(matches(error), "unexpected \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertLiveIsTeam(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(item.data, liveEnvelope, file: file, line: line)
        XCTAssertEqual(config.profile?.organizationUuid, "org-team", file: file, line: line)
    }

    private func assertNothingChanged(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(item.writes.isEmpty, "item written", file: file, line: line)
        XCTAssertEqual(store.writes, 0, "saved login written", file: file, line: line)
        XCTAssertEqual(config.writes, 0, "profile written", file: file, line: line)
        XCTAssertNil(journal.pending, file: file, line: line)
    }

    private func savedRecord(_ account: SavedAccount) throws -> SavedLoginRecord {
        try SavedLoginRecord(decoding: XCTUnwrap(store.items[account.id]))
    }

    // MARK: - Happy path

    func testSwitchSwapsOnlyClaudeAiOauthAndProfile() async throws {
        let outcome = try await switchToPersonal()
        XCTAssertEqual(outcome, .switched)

        let live = try Envelope(XCTUnwrap(item.data))
        XCTAssertEqual(try live.claudeAiOauth(), Fixture.oauth("personal"))
        XCTAssertEqual(live.member("mcpOAuth"), Data(#"{"server":{"accessToken":"mcp-secret"}}"#.utf8))
        XCTAssertEqual(live.member("other"), Data("[1,2]".utf8))
        XCTAssertEqual(config.profile?.organizationUuid, "org-personal")

        // Team's saved login now holds the live tokens it had before the switch.
        let teamBackup = try StoredLogin(decoding: XCTUnwrap(store.items[Fixture.team.id]))
        XCTAssertEqual(teamBackup.claudeAiOauth, Fixture.oauth("team-live"))
        XCTAssertEqual(teamBackup.profile.organizationUuid, "org-team")
        // The login the backup replaced is kept as `previous`.
        XCTAssertEqual(try savedRecord(Fixture.team).previous?.claudeAiOauth, Fixture.oauth("team-old"))

        // team-live didn't match Team's saved login, so the profile endpoint
        // proved it. Only the access token was sent.
        XCTAssertEqual(lookup.tokens, ["team-live-access"])
        XCTAssertEqual(item.preauthorizations, 1)
        XCTAssertNil(journal.pending)
    }

    func testSwitchingToTheActiveAccountDoesNothing() async throws {
        let outcome = try await makeSwitcher().switchTo(Fixture.team.id) { _ in true }
        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)
    }

    // MARK: - Aborts before any change

    func testUnknownOwnerAborts() async throws {
        config.profile = Fixture.profile(org: "org-unsaved")
        await assertThrows(.ownerUnknown) { try await self.switchToPersonal() }
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(config.writes, 0)
        XCTAssertEqual(store.writes, 0)
    }

    func testDecliningTheSessionWarningChangesNothing() async throws {
        sessions.sessions = [LiveSession(pid: 42, detail: "/tmp/project")]
        let outcome = try await switchToPersonal { sessions in
            sessions.map(\.pid) == [42] ? false : true
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)
    }

    func testBackupFailureMeansNoLiveWrite() async throws {
        store.failWrites = true
        await assertThrowsCase({ if case .backupFailed = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(config.writes, 0)
        try assertLiveIsTeam()
    }

    func testLiveTokenChangingBetweenStepsRetriesThenAborts() async throws {
        // Every read returns a newly refreshed token.
        item.onRead = { item, count in
            item.data = Fixture.envelope(Fixture.oauth("team-refresh-\(count)"))
        }
        await assertThrows(.liveLoginKeptChanging) { try await self.switchToPersonal() }
        XCTAssertEqual(item.reads, 6)  // steps 2 and 4, three times
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(config.writes, 0)
    }

    func testLiveTokenChangingOnceRetriesAndSucceeds() async throws {
        item.onRead = { item, count in
            if count == 2 { item.data = Fixture.envelope(Fixture.oauth("team-refreshed")) }
        }
        let outcome = try await switchToPersonal()
        XCTAssertEqual(outcome, .switched)
        let teamBackup = try StoredLogin(decoding: XCTUnwrap(store.items[Fixture.team.id]))
        XCTAssertEqual(teamBackup.claudeAiOauth, Fixture.oauth("team-refreshed"))
    }

    func testItemHoldingTargetLoginUnderOtherProfileAborts() async throws {
        item.data = Fixture.envelope(Fixture.oauth("personal"))
        await assertThrows(.liveLoginMismatch) { try await self.switchToPersonal() }
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)
    }

    func testEmptyLiveTokensAbortWithoutOverwritingTheBackup() async throws {
        item.data = Fixture.envelope(Data(#"{"accessToken":"","refreshToken":""}"#.utf8))
        await assertThrowsCase({ if case .liveLoginUnreadable = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        XCTAssertEqual(store.writes, 0)
    }

    func testTargetSavedForAnotherOrgAborts() async throws {
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-team")
        await assertThrowsCase({ if case .storedLoginInvalid = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        XCTAssertTrue(item.writes.isEmpty)
    }

    // MARK: - Rollback

    func testItemWriteFailureRollsBack() async throws {
        item.failWrite = { $0 == 1 ? TestFailure() : nil }
        await assertThrowsCase({ if case .rolledBack = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        try assertLiveIsTeam()
        // The failed write changed nothing, so the rollback found the
        // pre-switch envelope in place and didn't write again.
        XCTAssertEqual(item.writes.count, 1)
        XCTAssertNil(journal.pending)
    }

    func testProfileWriteFailureRollsBack() async throws {
        config.failWrite = { $0 == 1 ? TestFailure() : nil }
        await assertThrowsCase({ if case .rolledBack = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        try assertLiveIsTeam()
    }

    func testVerifyFailureRollsBack() async throws {
        // The first write reports success but doesn't store anything.
        item.writeTakesEffect = { $0 != 1 }
        await assertThrowsCase({ if case .rolledBack = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        try assertLiveIsTeam()
        XCTAssertEqual(config.writes, 2)  // switched, then restored
    }

    func testRollbackFailureIsBlocking() async throws {
        config.failWrite = { $0 == 1 ? TestFailure() : nil }  // step 6 fails
        item.failWrite = { $0 == 2 ? TestFailure() : nil }    // the rollback write fails
        do {
            _ = try await switchToPersonal()
            XCTFail("expected rollbackFailed")
        } catch let error as SwitchError {
            guard case .rollbackFailed = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isBlocking)
            XCTAssertTrue(error.message.contains("claude /login"))
        }
    }

    func testRollbackIsSkippedWhenTheItemChangedAfterTheSwitchWroteIt() async throws {
        config.failWrite = { $0 == 1 ? TestFailure() : nil }  // step 6 fails
        let rotated = Fixture.envelope(Fixture.oauth("personal-rotated"))
        // Read 1 is step 2, read 2 the in-process read before the write,
        // read 3 the rollback's re-read: Claude Code rotated the token first.
        item.onRead = { item, count in if count == 3 { item.data = rotated } }
        do {
            _ = try await switchToPersonal()
            XCTFail("expected rollbackSkipped")
        } catch let error as SwitchError {
            guard case .rollbackSkipped = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isBlocking)
        }
        XCTAssertEqual(item.data, rotated, "the rotated login must not be overwritten")
        XCTAssertEqual(item.writes.count, 1)
        XCTAssertEqual(config.writes, 1)  // the failed step 6 only; the profile wasn't touched after
        XCTAssertNotNil(journal.pending, "the journal stays so the recovery alert shows")
    }

    // MARK: - Ownership

    func testUnexpiredTokenFromAnotherOrgFails() async throws {
        lookup.prefixes = ["team-live": "org-personal"]
        await assertThrows(.liveLoginMismatch) { try await self.switchToPersonal() }
        assertNothingChanged()
        await assertThrows(.liveLoginMismatch) { try await self.makeSwitcher().saveCurrentLogin { _ in "x" } }
        assertNothingChanged()
    }

    func testExpiredTokenMatchingTheSavedBackupPasses() async throws {
        // Claude's item still holds the tokens Team's backup has, now expired.
        let old = Fixture.oauth("team-old", expiresAt: Fixture.expired)
        item.data = Fixture.envelope(old)
        store.items[Fixture.team.id] = try StoredLogin(claudeAiOauth: old, profile: Fixture.profile(org: "org-team")).encoded()
        lookup.result = .failed("must not be called")
        let outcome = try await switchToPersonal()
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(lookup.tokens, [])
    }

    func testExpiredTokenWithNoMatchFailsClosed() async throws {
        item.data = Fixture.envelope(Fixture.oauth("team-new", expiresAt: Fixture.expired))
        await assertThrows(.ownershipUnverified(SwitchError.expiredAndUnmatched)) { try await self.switchToPersonal() }
        assertNothingChanged()
        XCTAssertEqual(lookup.tokens, [], "an expired token isn't sent")
        XCTAssertTrue(SwitchError.ownershipUnverified(SwitchError.expiredAndUnmatched).message
            .contains("Use Claude Code once so it refreshes, then try again."))
        await assertThrows(.ownershipUnverified(SwitchError.expiredAndUnmatched)) {
            try await self.makeSwitcher().saveCurrentLogin { _ in "x" }
        }
        assertNothingChanged()
    }

    func testRejectedTokenFailsClosed() async throws {
        lookup.result = .unauthorized
        await assertThrows(.ownershipUnverified(SwitchError.expiredAndUnmatched)) { try await self.switchToPersonal() }
        assertNothingChanged()
    }

    func testCrossAccountRefreshTokenMatchFails() async throws {
        // ~/.claude.json names Team, but the item holds Personal's saved tokens.
        item.data = Fixture.envelope(Fixture.oauth("personal"))
        lookup.prefixes = ["personal": "org-team"]  // even a lying profile check can't override it
        await assertThrows(.liveLoginMismatch) { try await self.makeSwitcher().saveCurrentLogin { _ in "x" } }
        assertNothingChanged()

        // Switching to a third account runs the same check.
        let other = SavedAccount(id: "other-id", label: "Other", email: "me@x.com", orgUuid: "org-other")
        accounts.accounts.append(other)
        store.items[other.id] = try Fixture.stored("other", org: "org-other")
        let storeWritesBefore = store.writes
        await assertThrows(.liveLoginMismatch) { try await self.makeSwitcher().switchTo(other.id) { _ in true } }
        XCTAssertEqual(store.writes, storeWritesBefore)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(lookup.tokens, [])
    }

    func testNetworkErrorFailsClosed() async throws {
        lookup.result = .failed("network error -1009")
        await assertThrowsCase({ if case .ownershipUnverified(let why) = $0 { why.contains("-1009") } else { false } }) {
            try await self.switchToPersonal()
        }
        assertNothingChanged()
        await assertThrowsCase({ if case .ownershipUnverified = $0 { true } else { false } }) {
            try await self.makeSwitcher().saveCurrentLogin { _ in "x" }
        }
        assertNothingChanged()
    }

    func testUnreadableOtherSavedLoginFailsClosed() async throws {
        store.items[Fixture.personal.id] = Data("not json".utf8)
        await assertThrowsCase({ if case .ownershipUnverified = $0 { true } else { false } }) {
            try await self.makeSwitcher().saveCurrentLogin { _ in "x" }
        }
        assertNothingChanged()
    }

    func testProfileEndpointIsOnlySentAccessTokens() async throws {
        _ = try await makeSwitcher().saveCurrentLogin { _ in "x" }
        _ = try await switchToPersonal()
        XCTAssertFalse(lookup.tokens.isEmpty)
        XCTAssertTrue(lookup.tokens.allSatisfy { $0.hasSuffix("-access") }, "\(lookup.tokens)")
    }

    // MARK: - Keychain pinning and pre-authorization

    func testMoreThanOneClaudeItemAbortsBeforeAnyChange() async throws {
        item.uniqueError = ClaudeItem.Failure.notUnique(found: ["/a/login.keychain-db", "/b/other.keychain-db"],
                                                        expected: "/a/login.keychain-db")
        await assertThrows(.claudeItemNotUnique(found: ["/a/login.keychain-db", "/b/other.keychain-db"],
                                                expected: "/a/login.keychain-db")) {
            try await self.switchToPersonal()
        }
        assertNothingChanged()
        XCTAssertEqual(item.reads, 0)
    }

    func testDeclinedKeychainAccessAbortsBeforeTheBackup() async throws {
        item.preauthorizeError = ClaudeItem.Failure.readFailed(status: errSecUserCanceled)
        await assertThrowsCase({ if case .keychainAccessDenied = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        assertNothingChanged()
    }

    // MARK: - Pending-switch journal

    func testJournalIsWrittenBeforeTheItemWriteAndClearedOnSuccess() async throws {
        let seen = Box<PendingSwitch?>(nil)
        let journal = self.journal!
        item.onWrite = { _, count in if count == 1 { seen.value = journal.pending } }
        _ = try await switchToPersonal()
        XCTAssertEqual(seen.value, PendingSwitch(fromId: Fixture.team.id, toId: Fixture.personal.id, startedAt: Fixture.now))
        XCTAssertNil(journal.pending)
    }

    func testCrashAfterTheItemWriteBlocksSwitchingUntilRestored() async throws {
        // Capture what's on disk the moment the item write lands, as if the
        // app died right then: step 6 never ran.
        let crash = Box<(item: Data?, journal: PendingSwitch?, store: [String: Data])?>(nil)
        let (journal, store) = (self.journal!, self.store!)
        item.onWrite = { item, count in
            if count == 1 { crash.value = (item.data, journal.pending, store.items) }
        }
        _ = try await switchToPersonal()
        let state = try XCTUnwrap(crash.value)

        item = FakeItem(state.item)
        self.store = FakeStore()
        self.store.items = state.store
        config = FakeConfig(Fixture.profile(org: "org-team"))
        self.journal = FakeJournal()
        self.journal.pending = state.journal
        let relaunched = makeSwitcher()

        let pending = try await relaunched.unfinishedSwitch()
        XCTAssertEqual(pending?.fromId, Fixture.team.id)
        await assertThrows(.switchUnfinished) { try await relaunched.switchTo(Fixture.team.id) { _ in true } }
        await assertThrows(.switchUnfinished) { try await relaunched.saveCurrentLogin { _ in "x" } }
        await assertThrows(.switchUnfinished) { try await relaunched.restorePrevious(Fixture.team.id) }
        await assertThrows(.switchUnfinished) { try await relaunched.remove(Fixture.team.id) }
        XCTAssertTrue(item.writes.isEmpty)

        // "Restore Team" puts Team's backed-up login and profile back.
        _ = try await relaunched.restoreUnfinishedSwitch { _ in nil }
        let live = try Envelope(XCTUnwrap(item.data))
        XCTAssertEqual(try live.claudeAiOauth(), Fixture.oauth("team-live"))
        XCTAssertEqual(live.member("mcpOAuth"), Data(#"{"server":{"accessToken":"mcp-secret"}}"#.utf8))
        XCTAssertEqual(config.profile?.organizationUuid, "org-team")
        XCTAssertNil(self.journal.pending)
        // Personal's saved login is untouched by the recovery.
        XCTAssertEqual(try StoredLogin(decoding: XCTUnwrap(self.store.items[Fixture.personal.id])).claudeAiOauth,
                       Fixture.oauth("personal"))

        let outcome = try await relaunched.switchTo(Fixture.personal.id) { _ in true }
        XCTAssertEqual(outcome, .switched)
    }

    func testRestoreSavesARotatedLiveLoginBeforeOverwritingIt() async throws {
        // Interrupted Team → Personal; Claude Code then refreshed Personal's
        // tokens, so the live login is the only valid Personal copy.
        item.data = Fixture.envelope(Fixture.oauth("personal-rotated"))
        journal.pending = PendingSwitch(fromId: Fixture.team.id, toId: Fixture.personal.id, startedAt: Fixture.now)
        _ = try await makeSwitcher().restoreUnfinishedSwitch { _ in nil }
        XCTAssertEqual(try savedRecord(Fixture.personal).current.claudeAiOauth, Fixture.oauth("personal-rotated"))
        XCTAssertEqual(try savedRecord(Fixture.personal).previous?.claudeAiOauth, Fixture.oauth("personal"))
        XCTAssertEqual(try Envelope(XCTUnwrap(item.data)).claudeAiOauth(), Fixture.oauth("team-old"))
        XCTAssertNil(journal.pending)
    }

    func testRestoreRefusesWhenTheLiveLoginCantBeIdentified() async throws {
        item.data = Fixture.envelope(Fixture.oauth("mystery", expiresAt: Fixture.expired))
        let pending = PendingSwitch(fromId: Fixture.team.id, toId: Fixture.personal.id, startedAt: Fixture.now)
        journal.pending = pending
        await assertThrowsCase({ if case .ownershipUnverified = $0 { true } else { false } }) {
            try await self.makeSwitcher().restoreUnfinishedSwitch { _ in nil }
        }
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(journal.pending, pending)
    }

    func testIveFixedItClearsTheJournalOnly() async throws {
        journal.pending = PendingSwitch(fromId: Fixture.team.id, toId: Fixture.personal.id, startedAt: Fixture.now)
        try await makeSwitcher().dismissUnfinishedSwitch()
        XCTAssertNil(journal.pending)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(config.writes, 0)
    }

    // MARK: - One operation at a time

    func testOperationInProgressRejectsANewOne() async throws {
        sessions.sessions = [LiveSession(pid: 42, detail: "/tmp/project")]
        let switcher = makeSwitcher()
        let gate = Gate()
        let first = Task { try await switcher.switchTo(Fixture.personal.id) { _ in await gate.arrive() } }
        await gate.waitForArrival()

        await assertThrows(.busy) { try await switcher.switchTo(Fixture.personal.id) { _ in true } }
        await assertThrows(.busy) { try await switcher.rename(Fixture.team.id, to: "x") }
        await assertThrows(.busy) { try await switcher.remove(Fixture.team.id) }
        await assertThrows(.busy) { try await switcher.saveCurrentLogin { _ in "x" } }

        await gate.open(true)
        let outcome = try await first.value
        XCTAssertEqual(outcome, .switched)
        try await switcher.rename(Fixture.team.id, to: "Work")
        XCTAssertEqual(accounts.accounts.first?.label, "Work")
    }

    // MARK: - Save, remove, rename

    func testSaveUpdatesTheAccountWithTheSameOrg() async throws {
        let outcome = try await makeSwitcher().saveCurrentLogin { _ in
            XCTFail("an existing org must not ask for a label")
            return nil
        }
        guard case .updated(let account) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(account.id, Fixture.team.id)
        XCTAssertEqual(account.orgName, "ORG-TEAM")
        XCTAssertEqual(account.plan, "team")
        XCTAssertEqual(accounts.accounts.count, 2)
        let saved = try savedRecord(Fixture.team)
        XCTAssertEqual(saved.current.claudeAiOauth, Fixture.oauth("team-live"))
        XCTAssertEqual(saved.previous?.claudeAiOauth, Fixture.oauth("team-old"))
    }

    func testSavingTheSameTokensAgainKeepsTheOlderPrevious() async throws {
        _ = try await makeSwitcher().saveCurrentLogin { _ in nil }
        _ = try await makeSwitcher().saveCurrentLogin { _ in nil }
        XCTAssertEqual(try savedRecord(Fixture.team).previous?.claudeAiOauth, Fixture.oauth("team-old"))
    }

    func testRestorePreviousSwapsTheSavedLogins() async throws {
        _ = try await makeSwitcher().saveCurrentLogin { _ in nil }
        try await makeSwitcher().restorePrevious(Fixture.team.id)
        var record = try savedRecord(Fixture.team)
        XCTAssertEqual(record.current.claudeAiOauth, Fixture.oauth("team-old"))
        XCTAssertEqual(record.previous?.claudeAiOauth, Fixture.oauth("team-live"))
        // Again swaps back: nothing is lost.
        try await makeSwitcher().restorePrevious(Fixture.team.id)
        record = try savedRecord(Fixture.team)
        XCTAssertEqual(record.current.claudeAiOauth, Fixture.oauth("team-live"))
        XCTAssertEqual(record.previous?.claudeAiOauth, Fixture.oauth("team-old"))
        // The live login is never touched.
        try assertLiveIsTeam()
        XCTAssertTrue(item.writes.isEmpty)

        await assertThrows(.noPreviousLogin) { try await self.makeSwitcher().restorePrevious(Fixture.personal.id) }
    }

    func testRestorePreviousRefusesAnotherOrgsLogin() async throws {
        let mine = StoredLogin(claudeAiOauth: Fixture.oauth("team-old"), profile: Fixture.profile(org: "org-team"))
        let foreign = StoredLogin(claudeAiOauth: Fixture.oauth("personal"), profile: Fixture.profile(org: "org-personal"))
        let data = try SavedLoginRecord(current: mine, previous: foreign).encoded()
        store.items[Fixture.team.id] = data
        await assertThrowsCase({ if case .storedLoginInvalid = $0 { true } else { false } }) {
            try await self.makeSwitcher().restorePrevious(Fixture.team.id)
        }
        XCTAssertEqual(store.items[Fixture.team.id], data)
    }

    func testBackupNeverOverwritesAnUnreadableSavedLogin() async throws {
        store.items[Fixture.team.id] = Data("garbage".utf8)
        await assertThrowsCase({ if case .backupFailed = $0 { true } else { false } }) {
            try await self.makeSwitcher().saveCurrentLogin { _ in nil }
        }
        XCTAssertEqual(store.items[Fixture.team.id], Data("garbage".utf8))
    }

    func testLiveStatusDetectsATokenFromAnotherOrg() async throws {
        let consistent = try await makeSwitcher().liveLoginStatus()
        XCTAssertEqual(consistent, .consistent)

        lookup.prefixes = ["team-live": "org-personal"]
        let mismatch = try await makeSwitcher().liveLoginStatus()
        XCTAssertEqual(mismatch, .mismatch)

        lookup.result = .failed("offline")
        let unknown = try await makeSwitcher().liveLoginStatus()
        XCTAssertEqual(unknown, .unknown)

        // Personal's saved tokens under Team's profile: provable without the network.
        item.data = Fixture.envelope(Fixture.oauth("personal"))
        let crossed = try await makeSwitcher().liveLoginStatus()
        XCTAssertEqual(crossed, .mismatch)
        // Detection only.
        assertNothingChanged()
    }

    func testSaveAddsANewOrgWithItsLabel() async throws {
        accounts.accounts = [Fixture.personal]
        let outcome = try await makeSwitcher().saveCurrentLogin { suggestion in
            XCTAssertEqual(suggestion, "ORG-TEAM")
            return "  Acme  "
        }
        guard case .added(let account) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(account.label, "Acme")
        XCTAssertEqual(account.orgUuid, "org-team")
        XCTAssertEqual(accounts.accounts.map(\.label), ["Personal", "Acme"])
        XCTAssertNotNil(store.items[account.id])
    }

    func testSaveRefusesEmptyTokens() async throws {
        item.data = Fixture.envelope(Data(#"{"accessToken":"a","refreshToken":""}"#.utf8))
        await assertThrowsCase({ if case .liveLoginUnreadable = $0 { true } else { false } }) {
            try await self.makeSwitcher().saveCurrentLogin { _ in "x" }
        }
        XCTAssertEqual(store.writes, 0)
    }

    func testSaveAbortsIfTheLoginChangesWhileNaming() async throws {
        accounts.accounts = [Fixture.personal]
        let config = self.config!
        await assertThrows(.loginChangedDuringSave) {
            try await self.makeSwitcher().saveCurrentLogin { _ in
                config.profile = Fixture.profile(org: "org-other")
                return "Acme"
            }
        }
        XCTAssertEqual(store.writes, 0)
    }

    func testRemoveFailureKeepsMetadata() async throws {
        store.failDelete = AccountStore.Failure.status(-25293)
        await assertThrowsCase({ if case .removeFailed = $0 { true } else { false } }) {
            try await self.makeSwitcher().remove(Fixture.personal.id)
        }
        XCTAssertEqual(accounts.accounts.count, 2)
    }

    func testRemoveDeletesItemAndMetadataButNotTheLiveLogin() async throws {
        try await makeSwitcher().remove(Fixture.team.id)
        XCTAssertNil(store.items[Fixture.team.id])
        XCTAssertEqual(accounts.accounts, [Fixture.personal])
        try assertLiveIsTeam()
        XCTAssertTrue(item.writes.isEmpty)
    }

    func testRenameChangesOnlyTheLabel() async throws {
        try await makeSwitcher().rename(Fixture.personal.id, to: "Home")
        var expected = Fixture.personal
        expected.label = "Home"
        XCTAssertEqual(accounts.accounts.last, expected)
        await assertThrows(.invalidLabel) { try await self.makeSwitcher().rename(Fixture.personal.id, to: "  ") }
    }

    func testLiveOwnerIsFoundByOrgNotEmail() async throws {
        let owner = try await makeSwitcher().liveOwner()
        XCTAssertEqual(owner, Fixture.team)
        config.profile = Fixture.profile(org: "org-unsaved")
        let unknown = try await makeSwitcher().liveOwner()
        XCTAssertNil(unknown)
    }
}

final class SessionGuardTests: XCTestCase {
    func testFindsClaudeProcessesAndLiveSessionFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid":200,"sessionId":"a","cwd":"/work/app"}"#.utf8).write(to: directory.appendingPathComponent("200.json"))
        try Data(#"{"pid":300,"sessionId":"b"}"#.utf8).write(to: directory.appendingPathComponent("300.json"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))

        let guardian = SessionGuard(
            sessionsDirectory: directory,
            processes: {[
                RunningProcess(pid: 100, name: "claude", path: "/Users/me/.local/share/claude/versions/2.1.0"),
                RunningProcess(pid: 101, name: "node", path: "/usr/local/bin/node"),
                RunningProcess(pid: 102, name: "x", path: "/opt/bin/claude"),
            ]},
            isAlive: { $0 == 200 }
        )
        XCTAssertEqual(guardian.liveSessions().map(\.pid), [100, 102, 200])
        XCTAssertEqual(guardian.liveSessions().last?.detail, "/work/app")
    }

    func testMissingSessionsDirectoryIsFine() {
        let guardian = SessionGuard(sessionsDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                                    processes: { [] }, isAlive: { _ in true })
        XCTAssertEqual(guardian.liveSessions(), [])
    }
}
