import XCTest

/// Add account, driven with fakes. Team is live and saved, Personal is saved;
/// the fake runner stands in for `claude auth login` and changes the live
/// login the way the CLI would. No test runs the real `claude`.
final class AddAccountTests: XCTestCase {
    private var item: FakeItem!
    private var store: FakeStore!
    private var config: FakeConfig!
    private var accounts: FakeAccounts!
    private var lookup: FakeLookup!
    private var journal: FakeJournal!
    private var runner: FakeLoginRunner!
    private var directory: URL!
    private var cli: ClaudeCLI!
    /// The fake `claude`, symlinks resolved.
    private var resolved: String!

    private let environment = ClaudeCLI.loginEnvironment(home: "/Users/me", user: "me", temporaryDirectory: "/tmp/me/")
    private var liveEnvelope: Data { Fixture.envelope(Fixture.oauth("team-live")) }

    override func setUpWithError() throws {
        item = FakeItem(liveEnvelope)
        store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        config = FakeConfig(Fixture.profile(org: "org-team"))
        accounts = FakeAccounts([Fixture.team, Fixture.personal])
        lookup = FakeLookup(["team": "org-team", "personal": "org-personal", "new": "org-new"])
        journal = FakeJournal()
        runner = FakeLoginRunner()

        // A fake `claude` that is never run: a symlink in "bin" to an
        // executable file in "versions", plus a missing and a non-executable
        // candidate before it.
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccswitcher-cli-\(UUID().uuidString)")
        let versions = directory.appendingPathComponent("versions")
        let bin = directory.appendingPathComponent("bin")
        let plain = directory.appendingPathComponent("plain")
        for dir in [versions, bin, plain] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let target = versions.appendingPathComponent("2.1.0")
        try Data("not a real program".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: target)
        try Data("not executable".utf8).write(to: plain.appendingPathComponent("claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.appendingPathComponent("claude").path)
        resolved = target.resolvingSymlinksInPath().path
        cli = ClaudeCLI(candidates: [directory.appendingPathComponent("missing/claude").path,
                                     plain.appendingPathComponent("claude").path,
                                     bin.appendingPathComponent("claude").path],
                        environment: environment)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeSwitcher(cli: ClaudeCLI? = nil) -> Switcher {
        Switcher(item: item, store: store, config: config, accounts: accounts, sessions: FakeSessions(),
                 lookup: lookup, clock: FixedClock(date: Fixture.now), journal: journal,
                 cli: cli ?? self.cli, login: runner)
    }

    private func add(_ switcher: Switcher? = nil,
                     confirm: @escaping @Sendable (String) async -> Bool = { _ in true },
                     askLabel: @escaping @Sendable (String) async -> String? = { _ in "Mine" },
                     cancellation: LoginCancellation = LoginCancellation()) async throws -> AddAccountOutcome {
        try await (switcher ?? makeSwitcher()).addAccount(confirm: confirm, loginStarted: {}, askLabel: askLabel,
                                                          cancellation: cancellation)
    }

    private static func profile(org: String, name: String) -> OAuthProfile {
        OAuthProfile(fields: [
            "organizationUuid": AnyCodable(org),
            "emailAddress": AnyCodable("me@x.com"),
            "organizationName": AnyCodable(name),
        ])
    }

    /// Makes the fake CLI sign in to `org` with tokens named `name`.
    private func signIn(as name: String, org: String, orgName: String = "Profile Name") {
        let (item, config) = (self.item!, self.config!)
        let profile = Self.profile(org: org, name: orgName)
        runner.onRun = {
            item.data = Fixture.envelope(Fixture.oauth(name))
            config.profile = profile
        }
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

    private func savedRecord(_ id: String) throws -> SavedLoginRecord {
        try SavedLoginRecord(decoding: XCTUnwrap(store.items[id]))
    }

    private var pendingLogin: PendingSwitch {
        PendingSwitch(fromId: Fixture.team.id, toId: nil, kind: .login, startedAt: Fixture.now)
    }

    // MARK: - Happy path

    func testAddsANewOrganization() async throws {
        let (journal, store) = (self.journal!, self.store!)
        let atRun = Box<(journal: PendingSwitch?, team: Data?)>((nil, nil))
        let (item, config) = (self.item!, self.config!)
        let profile = Self.profile(org: "org-new", name: "Profile Name")
        runner.onRun = {
            atRun.value = (journal.pending, store.items[Fixture.team.id])
            item.data = Fixture.envelope(Fixture.oauth("new-live"))
            config.profile = profile
        }
        let confirmed = Box<String?>(nil)
        let suggested = Box<String?>(nil)
        let outcome = try await add(confirm: { label in confirmed.value = label; return true },
                                    askLabel: { suggestion in suggested.value = suggestion; return "  Mine  " })

        guard case .added(let account) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(confirmed.value, "Team")
        // The label defaults to the org name from the profile endpoint.
        XCTAssertEqual(suggested.value, "ORG-NEW")
        XCTAssertEqual(account.label, "Mine")
        XCTAssertEqual(account.orgUuid, "org-new")
        XCTAssertEqual(account.orgName, "Profile Name")
        XCTAssertEqual(account.email, "me@x.com")
        XCTAssertEqual(accounts.accounts.map(\.label), ["Team", "Personal", "Mine"])

        // Team was backed up (keeping `previous`) and the journal written
        // before the CLI ran.
        let teamAtRun = try SavedLoginRecord(decoding: XCTUnwrap(atRun.value.team))
        XCTAssertEqual(teamAtRun.current.claudeAiOauth, Fixture.oauth("team-live"))
        XCTAssertEqual(teamAtRun.previous?.claudeAiOauth, Fixture.oauth("team-old"))
        XCTAssertEqual(atRun.value.journal, pendingLogin)

        // The new login is saved and proven with its access token.
        let saved = try savedRecord(account.id)
        XCTAssertEqual(saved.current.claudeAiOauth, Fixture.oauth("new-live"))
        XCTAssertEqual(saved.current.profile.organizationUuid, "org-new")
        XCTAssertNil(saved.previous)
        XCTAssertEqual(lookup.tokens, ["team-live-access", "new-live-access"])

        XCTAssertNil(journal.pending)
        XCTAssertEqual(runner.commands.count, 1)
        // The CLI changes the live login; the app never writes it here.
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(config.writes, 0)
        XCTAssertEqual(outcome.message?.title, "Added Mine")
    }

    func testTheNewAccountBecomesTheLiveOwner() async throws {
        signIn(as: "new-live", org: "org-new")
        let switcher = makeSwitcher()
        guard case .added(let account) = try await add(switcher) else { return XCTFail() }
        let owner = try await switcher.liveOwner()
        XCTAssertEqual(owner?.id, account.id)
    }

    func testRunnerGetsTheResolvedArgvAndOnlyTheAllowlistedEnvironment() async throws {
        signIn(as: "new-live", org: "org-new")
        _ = try await add()
        XCTAssertEqual(runner.commands, [LoginCommand(argv: [resolved, "auth", "login", "--claudeai"], environment: environment)])
        XCTAssertTrue(resolved.hasSuffix("/versions/2.1.0"), resolved)
        XCTAssertEqual(runner.timeouts, [600])
        let env = try XCTUnwrap(runner.commands.first?.environment)
        XCTAssertEqual(Set(env.keys), ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "PATH"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["LOGNAME"], "me")
    }

    func testStandardCLILooksOnlyInTheFixedPlacesWithAFreshEnvironment() {
        let standard = ClaudeCLI.standard()
        XCTAssertEqual(standard.candidates, [NSHomeDirectory() + "/.local/bin/claude",
                                             "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        XCTAssertEqual(Set(standard.environment.keys), ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "PATH"])
        XCTAssertEqual(standard.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(standard.environment["USER"], NSUserName())
    }

    func testResolveSkipsMissingAndNonExecutableCandidates() throws {
        XCTAssertEqual(try cli.resolve(), resolved)
        let none = ClaudeCLI(candidates: [directory.appendingPathComponent("plain/claude").path], environment: [:])
        XCTAssertThrowsError(try none.resolve()) { error in
            XCTAssertEqual(error as? ClaudeCLI.Failure, .notFound(searched: none.candidates))
        }
    }

    // MARK: - Nothing changes

    func testUnchangedLiveTokenMeansSignInDidNotComplete() async throws {
        runner.end = .exited(1)
        let outcome = try await add(askLabel: { _ in XCTFail("no label without a new login"); return nil })
        XCTAssertEqual(outcome, .notCompleted(.exited(1)))
        XCTAssertEqual(outcome.message?.text, "Sign-in didn't complete; nothing changed.")
        XCTAssertNil(journal.pending)
        XCTAssertEqual(accounts.accounts, [Fixture.team, Fixture.personal])
        XCTAssertEqual(store.writes, 1, "only the backup")
        XCTAssertEqual(lookup.tokens, ["team-live-access"])
    }

    func testCancelOrTimeoutWithTheLiveLoginUnchangedClearsTheJournal() async throws {
        for end in [LoginEnd.cancelled, .timedOut] {
            runner.end = end
            let outcome = try await add()
            XCTAssertEqual(outcome, .notCompleted(end))
            XCTAssertNil(journal.pending)
            XCTAssertEqual(accounts.accounts.count, 2)
            XCTAssertEqual(item.data, liveEnvelope)
        }
        XCTAssertTrue(AddAccountOutcome.notCompleted(.timedOut).message?.text.contains("nothing changed") == true)
    }

    func testCancelAfterTheLoginChangedStillSettlesTheNewLogin() async throws {
        signIn(as: "new-live", org: "org-new")
        runner.end = .cancelled
        guard case .added = try await add() else { return XCTFail() }
        XCTAssertNil(journal.pending)
    }

    func testUnknownOwnerAbortsBeforeTheRunnerStarts() async throws {
        config.profile = Fixture.profile(org: "org-unsaved")
        await assertThrows(.ownerUnknown) {
            try await self.add(confirm: { _ in XCTFail("no confirm for an unknown owner"); return true })
        }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(journal.pending)
    }

    func testMissingClaudeAbortsBeforeAnything() async throws {
        await assertThrows(.claudeNotFound([])) { try await self.add(self.makeSwitcher(cli: Fixture.noCLI)) }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(journal.pending)
    }

    func testDecliningTheConfirmationChangesNothing() async throws {
        let outcome = try await add(confirm: { _ in false })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(outcome.message)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(journal.pending)
    }

    func testUnprovableOwnerAbortsBeforeTheRunnerStarts() async throws {
        lookup.prefixes["team"] = nil  // the profile check for team-live fails
        await assertThrowsCase({ if case .ownershipUnverified = $0 { true } else { false } }) { try await self.add() }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(journal.pending)
    }

    func testRunnerThatCantStartClearsTheJournalWhenNothingChanged() async throws {
        runner.error = TestFailure()
        await assertThrowsCase({ if case .loginDidNotStart = $0 { true } else { false } }) { try await self.add() }
        XCTAssertNil(journal.pending)
    }

    // MARK: - Saved organizations

    func testSigningInToASavedOrgUpdatesItAndKeepsPrevious() async throws {
        signIn(as: "personal-new", org: "org-personal")
        let outcome = try await add(askLabel: { _ in XCTFail("a saved org needs no label"); return nil })
        guard case .updated(let account) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(account.id, Fixture.personal.id)
        XCTAssertEqual(outcome.message?.text, "You signed in to Personal again; its saved login was updated.")
        let record = try savedRecord(Fixture.personal.id)
        XCTAssertEqual(record.current.claudeAiOauth, Fixture.oauth("personal-new"))
        XCTAssertEqual(record.previous?.claudeAiOauth, Fixture.oauth("personal"))
        XCTAssertEqual(accounts.accounts.count, 2)
        XCTAssertNil(journal.pending)
    }

    // MARK: - Unprovable results keep the journal

    func testProfileOrgDifferentFromOAuthAccountKeepsTheJournal() async throws {
        signIn(as: "new-live", org: "org-new")
        lookup.prefixes["new"] = "org-other"
        await assertThrows(.liveLoginMismatch) { try await self.add() }
        XCTAssertEqual(journal.pending, pendingLogin)
        XCTAssertEqual(accounts.accounts.count, 2)
        XCTAssertEqual(store.items.count, 2)
    }

    func testNetworkFailureAfterTheLoginChangedKeepsTheJournal() async throws {
        signIn(as: "new-live", org: "org-new")
        lookup.prefixes["new"] = nil  // the fake answers .failed
        await assertThrowsCase({ if case .newLoginUnverified = $0 { true } else { false } }) { try await self.add() }
        XCTAssertEqual(journal.pending, pendingLogin)
        XCTAssertEqual(accounts.accounts.count, 2)
    }

    func testMissingProfileAfterTheLoginKeepsTheJournal() async throws {
        let (item, config) = (self.item!, self.config!)
        runner.onRun = {
            item.data = Fixture.envelope(Fixture.oauth("new-live"))
            config.profile = nil
        }
        await assertThrowsCase({ if case .newLoginUnverified = $0 { true } else { false } }) { try await self.add() }
        XCTAssertEqual(journal.pending, pendingLogin)
    }

    func testProfileChangedButTokenDidNotKeepsTheJournal() async throws {
        let config = self.config!
        runner.onRun = { config.profile = Fixture.profile(org: "org-new") }
        await assertThrows(.liveLoginMismatch) { try await self.add() }
        XCTAssertEqual(journal.pending, pendingLogin)
    }

    // MARK: - Label prompt

    func testCancellingTheLabelLeavesTheLoginLiveAndUnsaved() async throws {
        signIn(as: "new-live", org: "org-new")
        let outcome = try await add(askLabel: { _ in nil })
        XCTAssertEqual(outcome, .unsaved)
        XCTAssertTrue(outcome.message?.text.contains("isn't saved yet") == true)
        XCTAssertTrue(outcome.message?.text.contains("Save current login…") == true)
        XCTAssertEqual(accounts.accounts.count, 2)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertNil(journal.pending)
        XCTAssertEqual(try Envelope(XCTUnwrap(item.data)).claudeAiOauth(), Fixture.oauth("new-live"))
    }

    func testLoginChangingWhileNamingKeepsTheJournal() async throws {
        signIn(as: "new-live", org: "org-new")
        let item = self.item!
        await assertThrows(.loginChangedDuringSave) {
            try await self.add(askLabel: { _ in
                item.data = Fixture.envelope(Fixture.oauth("new-rotated"))
                return "Mine"
            })
        }
        XCTAssertEqual(journal.pending, pendingLogin)
        XCTAssertEqual(accounts.accounts.count, 2)
    }

    // MARK: - One operation at a time

    func testOtherOperationsAreRejectedWhileSigningIn() async throws {
        let gate = Gate()
        runner.onRun = { _ = await gate.arrive() }
        let switcher = makeSwitcher()
        let started = Box(false)
        let running = Task {
            try await switcher.addAccount(confirm: { _ in true }, loginStarted: { started.value = true },
                                          askLabel: { _ in "x" }, cancellation: LoginCancellation())
        }
        await gate.waitForArrival()
        XCTAssertTrue(started.value)
        await assertThrows(.busy) { try await switcher.switchTo(Fixture.personal.id) { _ in true } }
        await assertThrows(.busy) { try await switcher.saveCurrentLogin { _ in "x" } }
        await assertThrows(.busy) {
            try await switcher.addAccount(confirm: { _ in true }, loginStarted: {}, askLabel: { _ in "x" },
                                          cancellation: LoginCancellation())
        }
        // The running operation's own journal isn't shown as an unfinished one.
        let shown = try await switcher.unfinishedSwitch()
        XCTAssertNil(shown)
        XCTAssertEqual(journal.pending, pendingLogin)

        await gate.open(true)
        let outcome = try await running.value
        XCTAssertEqual(outcome, .notCompleted(.exited(0)))
    }

    func testAnUnfinishedJournalBlocksAddAccount() async throws {
        journal.pending = PendingSwitch(fromId: Fixture.team.id, toId: Fixture.personal.id, startedAt: Fixture.now)
        await assertThrows(.switchUnfinished) { try await self.add() }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    // MARK: - Recovery after an unsettled Add account (toId == nil)

    /// Leaves a login journal behind: signed in to org-new, but the profile
    /// check failed.
    private func leaveUnsettledNewLogin() async throws {
        signIn(as: "new-live", org: "org-new")
        lookup.prefixes["new"] = nil
        await assertThrowsCase({ if case .newLoginUnverified = $0 { true } else { false } }) { try await self.add() }
        XCTAssertEqual(journal.pending, pendingLogin)
    }

    func testRecoverySavesTheUnsavedNewLoginThenRestores() async throws {
        try await leaveUnsettledNewLogin()
        lookup.prefixes["new"] = "org-new"  // back online
        let suggested = Box<String?>(nil)
        let outcome = try await makeSwitcher().restoreUnfinishedSwitch { suggestion in
            suggested.value = suggestion
            return "Mine"
        }
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(suggested.value, "Profile Name")
        let added = try XCTUnwrap(accounts.accounts.first { $0.label == "Mine" })
        XCTAssertEqual(added.orgUuid, "org-new")
        XCTAssertEqual(try savedRecord(added.id).current.claudeAiOauth, Fixture.oauth("new-live"))
        // Team's backed-up login is live again, with mcpOAuth kept.
        let live = try Envelope(XCTUnwrap(item.data))
        XCTAssertEqual(try live.claudeAiOauth(), Fixture.oauth("team-live"))
        XCTAssertEqual(live.member("mcpOAuth"), Data(#"{"server":{"accessToken":"mcp-secret"}}"#.utf8))
        XCTAssertEqual(config.profile?.organizationUuid, "org-team")
        XCTAssertNil(journal.pending)
    }

    func testRecoveryChangesNothingWhenTheSaveIsDeclined() async throws {
        try await leaveUnsettledNewLogin()
        lookup.prefixes["new"] = "org-new"
        let writes = store.writes
        let outcome = try await makeSwitcher().restoreUnfinishedSwitch { _ in nil }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(try Envelope(XCTUnwrap(item.data)).claudeAiOauth(), Fixture.oauth("new-live"))
        XCTAssertEqual(journal.pending, pendingLogin)
    }

    func testRecoveryRefusesWhenTheNewLoginCantBeProven() async throws {
        try await leaveUnsettledNewLogin()
        let writes = store.writes
        await assertThrowsCase({ if case .ownershipUnverified = $0 { true } else { false } }) {
            try await self.makeSwitcher().restoreUnfinishedSwitch { _ in
                XCTFail("an unproven login must not be offered for saving")
                return "x"
            }
        }
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(item.writes.isEmpty)
        XCTAssertEqual(journal.pending, pendingLogin)
    }

    func testRecoveryBacksUpALoginOfASavedOrgThenRestores() async throws {
        journal.pending = pendingLogin
        item.data = Fixture.envelope(Fixture.oauth("personal-new"))
        config.profile = Fixture.profile(org: "org-personal")
        let outcome = try await makeSwitcher().restoreUnfinishedSwitch { _ in XCTFail("no label for a saved org"); return nil }
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(try savedRecord(Fixture.personal.id).current.claudeAiOauth, Fixture.oauth("personal-new"))
        XCTAssertEqual(try Envelope(XCTUnwrap(item.data)).claudeAiOauth(), Fixture.oauth("team-old"))
        XCTAssertEqual(config.profile?.organizationUuid, "org-team")
        XCTAssertNil(journal.pending)
    }

    func testRecoveryWithTheLiveLoginUnchangedJustRestores() async throws {
        // Interrupted after the backup, before the CLI changed anything.
        journal.pending = pendingLogin
        store.items[Fixture.team.id] = try Fixture.stored("team-live", org: "org-team")
        let outcome = try await makeSwitcher().restoreUnfinishedSwitch { _ in nil }
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(try Envelope(XCTUnwrap(item.data)).claudeAiOauth(), Fixture.oauth("team-live"))
        XCTAssertNil(journal.pending)
        XCTAssertEqual(lookup.tokens, [])
    }
}

final class PendingSwitchCodingTests: XCTestCase {
    func testJournalsWrittenBeforeKindDecodeAsSwitches() throws {
        let old = Data(#"{"fromId":"a","toId":"b","startedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(PendingSwitch.self, from: old)
        XCTAssertEqual(decoded, PendingSwitch(fromId: "a", toId: "b", kind: .switch, startedAt: Date(timeIntervalSinceReferenceDate: 0)))
    }

    func testLoginJournalRoundTripsWithoutATarget() throws {
        let pending = PendingSwitch(fromId: "a", toId: nil, kind: .login, startedAt: Fixture.now)
        let data = try JSONEncoder().encode(pending)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["toId"])
        XCTAssertEqual(object["kind"] as? String, "login")
        XCTAssertEqual(try JSONDecoder().decode(PendingSwitch.self, from: data), pending)
    }
}
