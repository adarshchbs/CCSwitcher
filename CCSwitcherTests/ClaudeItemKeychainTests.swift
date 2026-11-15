import Security
import XCTest

/// `ClaudeItem` against a temporary keychain. The service name differs from
/// Claude Code's so nothing here can ever be mistaken for the real item.
final class ClaudeItemKeychainTests: XCTestCase {
    private static let service = "CCSwitcher Test-credentials"
    private static let account = "tester"

    private var keychain: TempKeychain!
    private var secKeychain: SecKeychain!
    private var runner: GuardedRunner!
    private var item: ClaudeItem!

    override func setUpWithError() throws {
        keychain = try TempKeychain()
        secKeychain = try keychain.open()
        runner = GuardedRunner(keychainPath: keychain.path)
        item = ClaudeItem(service: Self.service, account: Self.account,
                          keychainPath: keychain.path, keychain: secKeychain, runner: runner)
    }

    override func tearDownWithError() throws {
        try keychain.delete()
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
        try item.write(Data(#"{"v":1}"#.utf8))
        XCTAssertEqual(try keychain.accessControlDump(), before)
        XCTAssertEqual(try item.read(), Data(#"{"v":1}"#.utf8))
    }

    func testRoundTrips16KBPayloadWithQuotesSpacesAndUnicode() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let payload = Data(("{\"claudeAiOauth\":{\"accessToken\":\"a \\\"q\\\" ✓ é 日本\"},\"pad\":\""
            + String(repeating: "é \\\" x", count: 3000) + "\"}").utf8)
        XCTAssertGreaterThan(payload.count, 16_000)
        try item.write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testRoundTripsPlainASCII() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8)
        try item.write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testUpdatesInPlace() throws {
        try seed(Data(#"{"v":0}"#.utf8))
        try item.write(Data(#"{"v":1}"#.utf8))
        try item.write(Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try item.read(), Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try itemCount(), 1)
    }

    func testWriteToMissingItemIsNotFoundAndCreatesNothing() throws {
        XCTAssertThrowsError(try item.write(Data(#"{"v":1}"#.utf8))) { error in
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
        try item.write(payload)
        _ = try item.read()

        // Only the read spawns `security`; the write never does.
        XCTAssertEqual(runner.calls.count, 1)
        let argv = runner.calls[0].arguments.joined(separator: " ")
        XCTAssertFalse(argv.contains(secret))
        XCTAssertFalse(argv.contains(Data(secret.utf8).hexString))
        XCTAssertNil(runner.calls[0].stdin)
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
}
