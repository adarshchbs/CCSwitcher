import Security
import XCTest

/// `ClaudeItem` against a temporary keychain. The service name differs from
/// Claude Code's so nothing here can ever be mistaken for the real item.
final class ClaudeItemKeychainTests: XCTestCase {
    private static let service = "CCSwitcher Test-credentials"
    private static let account = "tester"

    private var keychain: TempKeychain!
    private var pin: KeychainPin!
    private var runner: GuardedRunner!
    private var item: ClaudeItem!
    private var extraKeychains: [TempKeychain] = []

    override func setUpWithError() throws {
        keychain = try TempKeychain()
        pin = try keychain.pin()
        runner = GuardedRunner(keychainPath: pin.path)
        // The search list is the temp keychain alone, never the user's.
        item = ClaudeItem(service: Self.service, account: Self.account,
                          keychain: pin, searchList: [pin.keychain], runner: runner)
    }

    override func tearDownWithError() throws {
        try keychain.delete()
        for extra in extraKeychains { try extra.delete() }
    }

    /// Writes through the in-process compare-and-write path.
    private func write(_ data: Data) throws {
        _ = try item.update { _ in data }
    }

    /// Creates the item in the temp keychain through `security`, as Claude
    /// Code does.
    private func seed(_ data: Data) throws {
        try keychain.seedGenericPassword(service: Self.service, account: Self.account,
                                         value: String(decoding: data, as: UTF8.self))
    }

    /// Claude Code keeps reading its item through `security` after a switch,
    /// so an update must change the data and nothing else about the item.
    func testUpdateLeavesAccessListUnchanged() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let before = try keychain.accessControlDump()
        try write(Data(#"{"v":1}"#.utf8))
        XCTAssertEqual(try keychain.accessControlDump(), before)
        XCTAssertEqual(try item.read(), Data(#"{"v":1}"#.utf8))
    }

    func testRoundTrips16KBPayloadWithQuotesSpacesAndUnicode() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let payload = Data(("{\"claudeAiOauth\":{\"accessToken\":\"a \\\"q\\\" ✓ é 日本\"},\"pad\":\""
            + String(repeating: "é \\\" x", count: 3000) + "\"}").utf8)
        XCTAssertGreaterThan(payload.count, 16_000)
        try write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testRoundTripsPlainASCII() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8)
        try write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testUpdatesInPlace() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        try write(Data(#"{"v":1}"#.utf8))
        try write(Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try item.read(), Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try itemCount(), 1)
    }

    func testWriteToMissingItemIsNotFoundAndCreatesNothing() throws {
        XCTAssertThrowsError(try write(Data(#"{"v":1}"#.utf8))) { error in
            XCTAssertEqual(error as? ClaudeItem.Failure, .notFound)
        }
        XCTAssertEqual(try itemCount(), 0)
    }

    func testReadOfMissingItemIsNotFound() {
        XCTAssertThrowsError(try item.read()) { error in
            XCTAssertEqual(error as? ClaudeItem.Failure, .notFound)
        }
    }

    func testSecretNeverAppearsInArgv() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let secret = "sk-ant-ort01-SECRET-\(UUID().uuidString)"
        let payload = Data(#"{"claudeAiOauth":{"refreshToken":"\#(secret)"}}"#.utf8)
        try write(payload)
        _ = try item.read()

        // Only the read spawns `security`; the write never does.
        XCTAssertEqual(runner.calls.count, 1)
        let argv = runner.calls[0].arguments.joined(separator: " ")
        XCTAssertFalse(argv.contains(secret))
        XCTAssertFalse(argv.contains(Data(secret.utf8).hexString))
        XCTAssertNil(runner.calls[0].stdin)
    }

    // MARK: - In-process read and write

    func testUpdatePassesTheCurrentBytesAndSpawnsNothing() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        try item.preauthorize()
        let seen = try item.update { current in
            XCTAssertEqual(current, Data(#"{"v":0}"#.utf8))
            return Data(#"{"v":1}"#.utf8)
        }
        XCTAssertEqual(seen, Data(#"{"v":0}"#.utf8))
        // The pre-flight read and the read-then-write ran in-process.
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(try item.read(), Data(#"{"v":1}"#.utf8))
    }

    func testUpdateWritesNothingWhenTransformDeclines() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let before = try keychain.accessControlDump()
        _ = try item.update { _ in nil }
        XCTAssertEqual(try item.read(), Data(#"{"v":0}"#.utf8))
        XCTAssertEqual(try keychain.accessControlDump(), before)
    }

    func testPreauthorizeOfMissingItemIsNotFound() {
        XCTAssertThrowsError(try item.preauthorize()) { error in
            XCTAssertEqual(error as? ClaudeItem.Failure, .notFound)
        }
    }

    // MARK: - Keychain pinning

    func testUniqueItemInThePinnedKeychainPasses() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        XCTAssertNoThrow(try item.requireUnique())
    }

    func testDuplicateInASecondKeychainOnTheSearchListFails() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let second = try TempKeychain()
        extraKeychains.append(second)
        try second.seedGenericPassword(service: Self.service, account: Self.account, value: #"{"v":9}"#)
        let secondPin = try second.pin()
        let searching = ClaudeItem(service: Self.service, account: Self.account, keychain: pin,
                                   searchList: [pin.keychain, secondPin.keychain], runner: runner)
        XCTAssertThrowsError(try searching.requireUnique()) { error in
            guard case .notUnique(let found, let expected) = error as? ClaudeItem.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(found.map(KeychainPin.canonical)),
                           [KeychainPin.canonical(self.pin.path), KeychainPin.canonical(secondPin.path)])
            XCTAssertEqual(expected, self.pin.path)
        }
    }

    func testOnlyCopyOutsideThePinnedKeychainFails() throws {
        let second = try TempKeychain()
        extraKeychains.append(second)
        try second.seedGenericPassword(service: Self.service, account: Self.account, value: #"{"v":9}"#)
        let secondPin = try second.pin()
        let searching = ClaudeItem(service: Self.service, account: Self.account, keychain: pin,
                                   searchList: [pin.keychain, secondPin.keychain], runner: runner)
        XCTAssertThrowsError(try searching.requireUnique()) { error in
            guard case .notUnique(let found, _) = error as? ClaudeItem.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(found.map(KeychainPin.canonical), [KeychainPin.canonical(secondPin.path)])
        }
    }

    func testNoItemAnywhereFails() {
        XCTAssertThrowsError(try item.requireUnique()) { error in
            XCTAssertEqual(error as? ClaudeItem.Failure, .notUnique(found: [], expected: self.pin.path))
        }
    }

    /// The whole switch against real temp keychains: a second copy of the
    /// item on the search list stops it before anything is read or written.
    func testSwitchAbortsWhenASecondKeychainHoldsTheItem() async throws {
        let live = Fixture.envelope(Fixture.oauth("team-live"))
        try seed(live)
        let second = try TempKeychain()
        extraKeychains.append(second)
        try second.seedGenericPassword(service: Self.service, account: Self.account,
                                       value: String(decoding: live, as: UTF8.self))
        let searching = ClaudeItem(service: Self.service, account: Self.account, keychain: pin,
                                   searchList: [pin.keychain, try second.open()], runner: runner)
        let store = FakeStore()
        store.items[Fixture.team.id] = try Fixture.stored("team-old", org: "org-team")
        store.items[Fixture.personal.id] = try Fixture.stored("personal", org: "org-personal")
        let journal = FakeJournal()
        let switcher = Switcher(item: searching, store: store, config: FakeConfig(Fixture.profile(org: "org-team")),
                                accounts: FakeAccounts([Fixture.team, Fixture.personal]), sessions: FakeSessions(),
                                lookup: FakeLookup(), clock: FixedClock(date: Fixture.now), journal: journal)
        do {
            _ = try await switcher.switchTo(Fixture.personal.id) { _ in true }
            XCTFail("expected claudeItemNotUnique")
        } catch let error as SwitchError {
            guard case .claudeItemNotUnique(let found, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found.count, 2)
        }
        XCTAssertEqual(try item.read(), live)
        XCTAssertEqual(store.writes, 0)
        XCTAssertNil(journal.pending)
    }

    private func itemCount() throws -> Int {
        let result = try SecurityTool().run(["dump-keychain", keychain.path], stdin: nil)
        return String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: "\"svce\"<blob>=\"\(Self.service)\"").count - 1
    }
}

final class ClaudeItemDecodingTests: XCTestCase {
    func testDecodesRawAndHexOutput() throws {
        let json = Data(#"{"a":"é"}"#.utf8)
        XCTAssertEqual(try ClaudeItem.decodePassword(json + Data("\n".utf8)), json)
        XCTAssertEqual(try ClaudeItem.decodePassword(Data((json.hexString + "\n").utf8)), json)
        XCTAssertThrowsError(try ClaudeItem.decodePassword(Data("not json\n".utf8)))
        XCTAssertThrowsError(try ClaudeItem.decodePassword(Data("6162\n".utf8)))  // hex, but not an object
    }

    func testAcceptsLeadingJSONWhitespace() throws {
        let raw = Data(" \t\r\n{\"a\":1}".utf8)
        XCTAssertEqual(try ClaudeItem.decodePassword(raw + Data("\n".utf8)), raw)
        XCTAssertEqual(try ClaudeItem.decodePassword(Data((raw.hexString + "\n").utf8)), raw)
        XCTAssertThrowsError(try ClaudeItem.decodePassword(Data("  [1]\n".utf8)))
    }
}
