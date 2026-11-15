import XCTest

final class EnvelopeTests: XCTestCase {
    /// Claude Code's item, with odd but valid formatting in the members that
    /// must survive: exotic numbers, escapes, nesting, whitespace.
    private let live = """
    { "mcpOAuth" : {"linear|abc": {"accessToken":"m\\u00e9\\"x","expiresAt":1.50e3,"scopes":["a","b"]}},
      "claudeAiOauth": {"accessToken":"old-a","refreshToken":"old-r","expiresAt":1700000000000,"subscriptionType":"team"},
      "futureKey": [1, 2.0, -0, true, null, "}]\\\\"] ,"another":{}
    }
    """

    private let replacement = Data(#"{"accessToken":"new-a","refreshToken":"new-r","expiresAt":1800000000000}"#.utf8)

    func testReplacingClaudeAiOauthKeepsOtherMembersByteForByte() throws {
        let before = try Envelope(Data(live.utf8))
        let after = try before.replacing("claudeAiOauth", with: replacement)

        XCTAssertEqual(try after.claudeAiOauth(), replacement)
        for key in ["mcpOAuth", "futureKey", "another"] {
            XCTAssertEqual(after.member(key), before.member(key), key)
            XCTAssertNotNil(after.member(key))
        }
        XCTAssertEqual(String(decoding: try XCTUnwrap(after.member("mcpOAuth")), as: UTF8.self),
                       #"{"linear|abc": {"accessToken":"m\u00e9\"x","expiresAt":1.50e3,"scopes":["a","b"]}}"#)
        XCTAssertEqual(String(decoding: try XCTUnwrap(after.member("futureKey")), as: UTF8.self),
                       #"[1, 2.0, -0, true, null, "}]\\"]"#)
        // Everything outside the replaced value is byte-identical too.
        let text = String(decoding: after.bytes, as: UTF8.self)
        XCTAssertEqual(text.replacingOccurrences(of: String(decoding: replacement, as: UTF8.self),
                                                 with: #"{"accessToken":"old-a","refreshToken":"old-r","expiresAt":1700000000000,"subscriptionType":"team"}"#),
                       live)
    }

    func testAddsClaudeAiOauthWhenMissing() throws {
        let envelope = try Envelope(Data(#"{"mcpOAuth":{"x":1}}"#.utf8))
        let after = try envelope.replacing("claudeAiOauth", with: replacement)
        XCTAssertEqual(after.member("mcpOAuth"), Data(#"{"x":1}"#.utf8))
        XCTAssertEqual(try after.claudeAiOauth(), replacement)

        let empty = try Envelope(Data("{ }".utf8)).replacing("claudeAiOauth", with: replacement)
        XCTAssertEqual(try empty.claudeAiOauth(), replacement)
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try Envelope(Data("[]".utf8)))
        XCTAssertThrowsError(try Envelope(Data("{".utf8)))
        XCTAssertThrowsError(try Envelope(Data(#"{"a":1,"a":2}"#.utf8))) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("a"))
        }
        XCTAssertThrowsError(try Envelope(Data("{}".utf8)).claudeAiOauth())
        XCTAssertThrowsError(try Envelope(Data("{}".utf8)).replacing("claudeAiOauth", with: Data("[1]".utf8)))
    }

    func testEscapedKeysAreDecoded() throws {
        // `\u0041` is "A": the key decodes to claudeAiOauth.
        let envelope = try Envelope(Data(#"{"claude\u0041iOauth":{"a":1}}"#.utf8))
        XCTAssertEqual(try envelope.claudeAiOauth(), Data(#"{"a":1}"#.utf8))
    }

    func testEscapedDuplicateKeyIsRejected() {
        XCTAssertThrowsError(try Envelope(Data(#"{"claudeAiOauth":{},"claude\u0041iOauth":{}}"#.utf8))) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("claudeAiOauth"))
        }
    }

    func testNestedDuplicatesInClaudeAiOauthAreRejected() throws {
        let plain = try Envelope(Data(#"{"claudeAiOauth":{"refreshToken":"a","refreshToken":"b"}}"#.utf8))
        XCTAssertThrowsError(try plain.claudeAiOauth()) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("refreshToken"))
        }
        let escaped = try Envelope(Data(#"{"claudeAiOauth":{"refreshToken":"a","refresh\u0054oken":"b"}}"#.utf8))
        XCTAssertThrowsError(try escaped.claudeAiOauth()) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("refreshToken"))
        }
        let deep = try Envelope(Data(#"{"claudeAiOauth":{"scopes":[1,{"k":1,"x":{"k":2},"k":3}]}}"#.utf8))
        XCTAssertThrowsError(try deep.claudeAiOauth()) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("k"))
        }
        // Same key in sibling objects is fine.
        let siblings = try Envelope(Data(#"{"claudeAiOauth":{"a":{"k":1},"b":{"k":2},"c":[{"k":1},{"k":2}]}}"#.utf8))
        XCTAssertNoThrow(try siblings.claudeAiOauth())

        XCTAssertThrowsError(try OAuthLogin(raw: Data(#"{"accessToken":"a","refreshToken":"r","refreshToken":"s"}"#.utf8)))
        XCTAssertThrowsError(try Envelope(Data("{}".utf8))
            .replacing("claudeAiOauth", with: Data(#"{"accessToken":"a","accessToken":"b"}"#.utf8)))
    }

    func testOtherMembersKeepTheirDuplicatesUntouched() throws {
        // Not ours to judge: mcpOAuth survives a switch byte for byte.
        let envelope = try Envelope(Data(#"{"mcpOAuth":{"x":1,"x":2},"claudeAiOauth":{"a":1}}"#.utf8))
        let after = try envelope.replacing("claudeAiOauth", with: replacement)
        XCTAssertEqual(after.member("mcpOAuth"), Data(#"{"x":1,"x":2}"#.utf8))
    }

    func testNestedDuplicatesInOAuthAccountAreRejected() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"},"oauthAccount":{"organizationUuid":"org-1","organization\u0055uid":"org-2"}}"#.utf8)
        XCTAssertThrowsError(try StoredLogin(decoding: data)) {
            XCTAssertEqual($0 as? Envelope.Failure, .duplicateKey("organizationUuid"))
        }
    }

    func testRecordKeepsOnePreviousGeneration() throws {
        let profile = OAuthProfile(fields: ["organizationUuid": AnyCodable("org-1")])
        let one = StoredLogin(claudeAiOauth: Data(#"{"accessToken":"a1","refreshToken":"r1"}"#.utf8), profile: profile)
        let two = StoredLogin(claudeAiOauth: Data(#"{"accessToken":"a2","refreshToken":"r2"}"#.utf8), profile: profile)
        let three = StoredLogin(claudeAiOauth: Data(#"{"accessToken":"a3","refreshToken":"r3"}"#.utf8), profile: profile)
        // An item from before `previous` existed decodes without one.
        let legacy = try SavedLoginRecord(decoding: try one.encoded())
        XCTAssertNil(legacy.previous)
        let record = legacy.replacingCurrent(with: two).replacingCurrent(with: three)
        let decoded = try SavedLoginRecord(decoding: try record.encoded())
        XCTAssertEqual(decoded.current.claudeAiOauth, three.claudeAiOauth)
        XCTAssertEqual(decoded.previous?.claudeAiOauth, two.claudeAiOauth)
        XCTAssertNil(try Envelope(try XCTUnwrap(Envelope(try record.encoded()).member("previous"))).member("previous"))
        // Older code reading the item still finds the current login.
        XCTAssertEqual(try StoredLogin(decoding: try record.encoded()).claudeAiOauth, three.claudeAiOauth)
    }

    func testLoginRequiresBothTokens() throws {
        let login = try OAuthLogin(raw: replacement)
        XCTAssertEqual(login.refreshToken, "new-r")
        XCTAssertEqual(login.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertThrowsError(try OAuthLogin(raw: Data(#"{"accessToken":"","refreshToken":"r"}"#.utf8)))
        XCTAssertThrowsError(try OAuthLogin(raw: Data(#"{"accessToken":"a","refreshToken":""}"#.utf8)))
        XCTAssertThrowsError(try OAuthLogin(raw: Data(#"{"accessToken":"a"}"#.utf8)))
    }

    func testStoredLoginRoundTrip() throws {
        let profile = OAuthProfile(fields: ["organizationUuid": AnyCodable("org-1"), "emailAddress": AnyCodable("me@x.com")])
        let stored = StoredLogin(claudeAiOauth: replacement, profile: profile)
        let decoded = try StoredLogin(decoding: try stored.encoded())
        XCTAssertEqual(decoded.claudeAiOauth, replacement)
        XCTAssertEqual(decoded.profile.organizationUuid, "org-1")
        XCTAssertEqual(try decoded.encoded(), try stored.encoded())
    }
}

final class OwnerDetectionTests: XCTestCase {
    private let team = SavedAccount(id: "1", label: "Team", email: "me@x.com", orgUuid: "org-team")
    private let personal = SavedAccount(id: "2", label: "Personal", email: "me@x.com", orgUuid: "org-personal")

    func testSameEmailDifferentOrgsResolveByOrg() {
        XCTAssertEqual([team, personal].owner(ofOrg: "org-team"), team)
        XCTAssertEqual([team, personal].owner(ofOrg: "org-personal"), personal)
    }

    func testNoOrgMatchIsUnknown() {
        XCTAssertNil([team, personal].owner(ofOrg: "org-other"))
        XCTAssertNil([team, personal].owner(ofOrg: nil))
        XCTAssertNil([team, personal].owner(ofOrg: ""))
    }

    func testDuplicateOrgIsUnknown() {
        var copy = personal
        copy.orgUuid = "org-team"
        XCTAssertNil([team, copy].owner(ofOrg: "org-team"))
    }
}

