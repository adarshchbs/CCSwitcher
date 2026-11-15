import Foundation

/// The JSON object stored in Claude Code's Keychain item. Its `claudeAiOauth`
/// member is the Claude login; other members (`mcpOAuth` and anything newer)
/// belong to Claude Code and must survive a switch untouched.
///
/// The envelope keeps the original bytes and the byte range of each top-level
/// member, and a replace splices new bytes into one range. Every other byte
/// stays exactly as Claude Code wrote it, with no decode/re-encode round trip.
struct Envelope: Equatable, Sendable {
    enum Failure: Error, Equatable {
        case notAJSONObject
        case duplicateKey(String)
        case missingMember(String)
        case invalidLogin(String)
    }

    let bytes: Data
    private let ranges: [String: Range<Int>]
    private let closingBrace: Int

    init(_ data: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw Failure.notAJSONObject
        }
        var scanner = MemberScanner(bytes: [UInt8](data))
        (ranges, closingBrace) = try scanner.scanTopLevelObject()
        bytes = data
    }

    /// The raw bytes of a top-level member's value.
    func member(_ key: String) -> Data? {
        ranges[key].map { bytes.subdata(in: $0) }
    }

    /// The raw `claudeAiOauth` value, required to be present and free of
    /// duplicate keys at any depth.
    func claudeAiOauth() throws -> Data {
        guard let raw = member("claudeAiOauth") else { throw Failure.missingMember("claudeAiOauth") }
        try Self.rejectDuplicateKeys(in: raw)
        return raw
    }

    /// Throws `duplicateKey` if any object inside the JSON value `raw`, at
    /// any depth, repeats a key (after decoding escapes). Parsers disagree on
    /// which copy wins, so a login with two `refreshToken`s is ambiguous.
    static func rejectDuplicateKeys(in raw: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) != nil else {
            throw Failure.notAJSONObject
        }
        var scanner = MemberScanner(bytes: [UInt8](raw))
        try scanner.walkValue()
    }

    /// A copy with `key`'s value replaced by `raw` (a JSON object), or added
    /// at the end when the key is missing. All other bytes are unchanged.
    func replacing(_ key: String, with raw: Data) throws -> Envelope {
        guard (try? JSONSerialization.jsonObject(with: raw)) is [String: Any] else {
            throw Failure.notAJSONObject
        }
        try Self.rejectDuplicateKeys(in: raw)
        var out = Data()
        if let range = ranges[key] {
            out.append(bytes.subdata(in: 0..<range.lowerBound))
            out.append(raw)
            out.append(bytes.subdata(in: range.upperBound..<bytes.count))
        } else {
            let keyJSON = try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed)
            out.append(bytes.subdata(in: 0..<closingBrace))
            if !ranges.isEmpty { out.append(Data(",".utf8)) }
            out.append(keyJSON)
            out.append(Data(":".utf8))
            out.append(raw)
            out.append(bytes.subdata(in: closingBrace..<bytes.count))
        }
        return try Envelope(out)
    }
}

/// The parts of a `claudeAiOauth` value the app reads.
struct OAuthLogin: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// `expiresAt` is milliseconds since 1970 in Claude Code's format.
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// Parses a raw `claudeAiOauth` value. Both tokens must be non-empty: an
    /// envelope with empty tokens (left behind by a logout) is not a login.
    init(raw: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw Envelope.Failure.notAJSONObject
        }
        try Envelope.rejectDuplicateKeys(in: raw)
        guard let access = object["accessToken"] as? String, !access.isEmpty else {
            throw Envelope.Failure.invalidLogin("accessToken is missing or empty")
        }
        guard let refresh = object["refreshToken"] as? String, !refresh.isEmpty else {
            throw Envelope.Failure.invalidLogin("refreshToken is missing or empty")
        }
        accessToken = access
        refreshToken = refresh
        expiresAt = (object["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        subscriptionType = object["subscriptionType"] as? String
        rateLimitTier = object["rateLimitTier"] as? String
    }

    func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Finds the byte range of each top-level member value in a JSON object, and
/// finds duplicate keys at any depth. Runs only on input that
/// `JSONSerialization` already accepted, so it can assume well-formed JSON.
private struct MemberScanner {
    let bytes: [UInt8]
    var i = 0

    mutating func scanTopLevelObject() throws -> ([String: Range<Int>], Int) {
        var ranges: [String: Range<Int>] = [:]
        skipWhitespace()
        try expect(UInt8(ascii: "{"))
        skipWhitespace()
        if peek == UInt8(ascii: "}") { return (ranges, i) }
        while true {
            let keyRange = try scanString()
            let key = try decodeKey(bytes[keyRange])
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            let valueRange = try scanValue()
            guard ranges[key] == nil else { throw Envelope.Failure.duplicateKey(key) }
            ranges[key] = valueRange
            skipWhitespace()
            if peek == UInt8(ascii: ",") {
                i += 1
                skipWhitespace()
                continue
            }
            guard peek == UInt8(ascii: "}") else { throw Envelope.Failure.notAJSONObject }
            return (ranges, i)
        }
    }

    /// Walks one JSON value, throwing `duplicateKey` for any object that
    /// repeats a key.
    mutating func walkValue() throws {
        skipWhitespace()
        switch peek {
        case UInt8(ascii: "{"):
            i += 1
            skipWhitespace()
            if peek == UInt8(ascii: "}") { i += 1; return }
            var keys = Set<String>()
            while true {
                let key = try decodeKey(bytes[try scanString()])
                guard keys.insert(key).inserted else { throw Envelope.Failure.duplicateKey(key) }
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                try walkValue()
                skipWhitespace()
                if peek == UInt8(ascii: ",") { i += 1; skipWhitespace(); continue }
                try expect(UInt8(ascii: "}"))
                return
            }
        case UInt8(ascii: "["):
            i += 1
            skipWhitespace()
            if peek == UInt8(ascii: "]") { i += 1; return }
            while true {
                try walkValue()
                skipWhitespace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                try expect(UInt8(ascii: "]"))
                return
            }
        default:
            _ = try scanValue()
        }
    }

    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func expect(_ byte: UInt8) throws {
        guard peek == byte else { throw Envelope.Failure.notAJSONObject }
        i += 1
    }

    private mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 }
    }

    private mutating func scanString() throws -> Range<Int> {
        let start = i
        try expect(UInt8(ascii: "\""))
        while let b = peek {
            i += 1
            if b == UInt8(ascii: "\\") { i += 1 }
            else if b == UInt8(ascii: "\"") { return start..<i }
        }
        throw Envelope.Failure.notAJSONObject
    }

    private mutating func scanValue() throws -> Range<Int> {
        let start = i
        switch peek {
        case UInt8(ascii: "\""):
            return try scanString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while let b = peek {
                if b == UInt8(ascii: "\"") { _ = try scanString(); continue }
                i += 1
                if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { depth += 1 }
                if b == UInt8(ascii: "}") || b == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return start..<i }
                }
            }
            throw Envelope.Failure.notAJSONObject
        default:
            // A number, true, false or null: runs to the next delimiter.
            while let b = peek, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                  0x20, 0x09, 0x0A, 0x0D].contains(b) { i += 1 }
            guard i > start else { throw Envelope.Failure.notAJSONObject }
            return start..<i
        }
    }

    private func decodeKey(_ raw: ArraySlice<UInt8>) throws -> String {
        guard let key = (try? JSONSerialization.jsonObject(with: Data(raw), options: .fragmentsAllowed)) as? String else {
            throw Envelope.Failure.notAJSONObject
        }
        return key
    }
}
