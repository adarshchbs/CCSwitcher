import XCTest

/// The switch state machine, driven with fakes. Team is live; the tests switch
/// to Personal, which has the same email address and a different org.
final class SwitcherTests: XCTestCase {
    private var item: FakeItem!
    private var store: FakeStore!
    private var config: FakeConfig!
    private var accounts: FakeAccounts!
    private var sessions = FakeSessions()

    private var liveEnvelope: Data { Fixture.envelope(Fixture.oauth("team-live")) }

    override func setUpWithError() throws {
        item = FakeItem(liveEnvelope)
        store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        config = FakeConfig(Fixture.profile(org: "org-team"))
        accounts = FakeAccounts([Fixture.team, Fixture.personal])
    }

    private func makeSwitcher() -> Switcher {
        Switcher(item: item, store: store, config: config, accounts: accounts, sessions: sessions)
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

    func testEnvelopeTooLargeToWriteAborts() async throws {
        item.maxBytes = 10
        await assertThrowsCase({ if case .tooLargeToWrite = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(config.writes, 0)
    }

    // MARK: - Rollback

    func testItemWriteFailureRollsBack() async throws {
        item.failWrite = { $0 == 1 ? TestFailure() : nil }
        await assertThrowsCase({ if case .rolledBack = $0 { true } else { false } }) {
            try await self.switchToPersonal()
        }
        try assertLiveIsTeam()
        XCTAssertEqual(item.writes.count, 2)
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
        let saved = try StoredLogin(decoding: XCTUnwrap(store.items[Fixture.team.id]))
        XCTAssertEqual(saved.claudeAiOauth, Fixture.oauth("team-live"))
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
