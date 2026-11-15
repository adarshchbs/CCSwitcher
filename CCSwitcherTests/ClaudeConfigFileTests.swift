import XCTest

/// `ClaudeConfig` against files in a temp directory, never `~/.claude.json`.
final class ClaudeConfigFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccswitcher-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ json: String, mode: Int16 = 0o600) throws -> String {
        let path = directory.appendingPathComponent("claude.json").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(json.utf8),
                                                     attributes: [.posixPermissions: mode]))
        return path
    }

    private let profile = OAuthProfile(fields: [
        "organizationUuid": AnyCodable("org-2"),
        "emailAddress": AnyCodable("me@x.com"),
    ])

    func testWritesProfileAndKeepsPermissions() throws {
        let path = try makeFile(#"{"numStartups": 3, "oauthAccount": {"organizationUuid": "org-1"}}"#, mode: 0o640)
        let config = ClaudeConfig(path: path)
        XCTAssertEqual(try config.readProfile().organizationUuid, "org-1")

        try config.writeProfile(profile)

        XCTAssertEqual(try config.readProfile().organizationUuid, "org-2")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(json["numStartups"] as? Int, 3)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["claude.json"])
    }

    func testWritesThroughSymlink() throws {
        let target = try makeFile(#"{"oauthAccount": {"organizationUuid": "org-1"}}"#)
        let link = directory.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        try ClaudeConfig(path: link).writeProfile(profile)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
        XCTAssertEqual(try ClaudeConfig(path: target).readProfile().organizationUuid, "org-2")
    }

    func testMissingFileOrBlockFails() throws {
        XCTAssertThrowsError(try ClaudeConfig(path: directory.appendingPathComponent("nope").path).readProfile())
        let path = try makeFile(#"{"numStartups": 1}"#)
        XCTAssertThrowsError(try ClaudeConfig(path: path).readProfile()) {
            XCTAssertEqual($0 as? ClaudeConfig.Failure, .noOAuthAccount)
        }
    }
}
