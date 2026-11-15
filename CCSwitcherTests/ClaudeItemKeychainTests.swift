import XCTest

/// `ClaudeItem` against a temporary keychain. The service name differs from
/// Claude Code's so nothing here can ever be mistaken for the real item.
final class ClaudeItemKeychainTests: XCTestCase {
    private var keychain: TempKeychain!
    private var runner: GuardedRunner!
    private var item: ClaudeItem!

    override func setUpWithError() throws {
        keychain = try TempKeychain()
        runner = GuardedRunner(keychainPath: keychain.path)
        item = ClaudeItem(service: "CCSwitcher Test-credentials", account: "tester",
                          keychainPath: keychain.path, runner: runner)
    }

    override func tearDownWithError() throws {
        try keychain.delete()
    }

    /// The largest envelope that fits on one `security -i` line, made of
    /// quotes, spaces and non-ASCII text.
    private func largestPayload() -> Data {
        var payload = #"{"claudeAiOauth":{"accessToken":"a \"quoted\" token ✓ é 日本","refreshToken":"r"},"pad":""#
        while item.canWrite(Data((payload + "x\"}").utf8)) { payload += "x" }
        return Data((payload + "\"}").utf8)
    }

    func testRoundTripsTheLargestPayloadWithQuotesSpacesAndUnicode() throws {
        let payload = largestPayload()
        XCTAssertGreaterThan(payload.count, 1900)
        try item.write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testRoundTripsPlainASCII() throws {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8)
        try item.write(payload)
        XCTAssertEqual(try item.read(), payload)
    }

    func testRefuses16KBPayloadBeforeStartingSecurity() throws {
        let payload = Data(("{\"pad\":\"" + String(repeating: "é \\\" ", count: 3000) + "\"}").utf8)
        XCTAssertGreaterThan(payload.count, 16_000)
        XCTAssertFalse(item.canWrite(payload))
        XCTAssertThrowsError(try item.write(payload)) { error in
            guard case ClaudeItem.Failure.tooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUpdatesInPlace() throws {
        try item.write(Data(#"{"v":1}"#.utf8))
        try item.write(Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try item.read(), Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try itemCount(), 1)
    }

    func testReadOfMissingItemIsNotFound() {
        XCTAssertThrowsError(try item.read()) { error in
            XCTAssertEqual(error as? ClaudeItem.Failure, .notFound)
        }
    }

    func testRefusesBadAccountNames() {
        for name in ["", "a b", "a\"b", "a\nb", "a;b", "ü"] {
            let bad = ClaudeItem(service: "CCSwitcher Test-credentials", account: name,
                                 keychainPath: keychain.path, runner: runner)
            XCTAssertThrowsError(try bad.write(Data("{}".utf8))) { error in
                XCTAssertEqual(error as? ClaudeItem.Failure, .invalidName(name))
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSecretNeverAppearsInArgv() throws {
        let secret = "sk-ant-ort01-SECRET-\(UUID().uuidString)"
        let payload = Data(#"{"claudeAiOauth":{"refreshToken":"\#(secret)"}}"#.utf8)
        try item.write(payload)
        _ = try item.read()

        XCTAssertEqual(runner.calls.count, 2)
        for call in runner.calls {
            let argv = call.arguments.joined(separator: " ")
            XCTAssertFalse(argv.contains(secret))
            XCTAssertFalse(argv.contains(payload.hexString))
            XCTAssertFalse(argv.contains(Data(secret.utf8).hexString))
        }
        XCTAssertEqual(runner.calls[0].arguments, ["-i"])
        let stdin = String(decoding: try XCTUnwrap(runner.calls[0].stdin), as: UTF8.self)
        XCTAssertTrue(stdin.contains(" -X \(payload.hexString) "))
    }

    private func itemCount() throws -> Int {
        let result = try SecurityTool().run(["dump-keychain", keychain.path], stdin: nil)
        return String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: "\"svce\"<blob>=\"CCSwitcher Test-credentials\"").count - 1
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
