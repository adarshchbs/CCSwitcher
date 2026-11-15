import Foundation
import Security

/// Stores each saved account's login in the app's own Keychain items.
protocol SavedLoginStore: Sendable {
    func read(id: String) throws -> Data
    func write(id: String, data: Data) throws
    func delete(id: String) throws
}

/// One generic-password item per saved account: service
/// `com.adarshchbs.ccswitcher.account`, account `<SavedAccount.id>`, never
/// synchronized to iCloud.
final class AccountStore: SavedLoginStore, @unchecked Sendable {
    // `@unchecked Sendable`: every property is immutable after init, and the
    // Keychain APIs are thread-safe.

    enum Failure: Error, Equatable {
        case notFound
        case noData
        case status(OSStatus)
    }

    static let accountService = "com.adarshchbs.ccswitcher.account"

    private let service: String
    /// Tests aim the store at a temporary keychain. Production passes nil
    /// and uses the default keychain.
    private let keychain: SecKeychain?

    init(service: String = accountService, keychain: SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }

    func read(id: String) throws -> Data {
        var query = matchQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try check(status)
        guard let data = item as? Data else { throw Failure.noData }
        return data
    }

    func write(id: String, data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(matchQuery(id: id) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return try check(status) }

        var add = baseQuery(id: id)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "CCSwitcher saved login"
        if let keychain { add[kSecUseKeychain as String] = keychain }
        try check(SecItemAdd(add as CFDictionary, nil))
    }

    func delete(id: String) throws {
        try check(SecItemDelete(matchQuery(id: id) as CFDictionary))
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            // The file-based login keychain, where Claude Code's item also
            // lives (and where `kSecUseKeychain` is honored).
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private func matchQuery(id: String) -> [String: Any] {
        var query = baseQuery(id: id)
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw Failure.notFound
        default: throw Failure.status(status)
        }
    }
}

/// What a saved account's Keychain item holds:
/// `{"claudeAiOauth": {...}, "oauthAccount": {...}}`.
///
/// `claudeAiOauth` keeps the exact bytes read from Claude Code's item, so a
/// switch writes back exactly what was saved.
struct StoredLogin: Sendable {
    enum Failure: Error, Equatable {
        case missingProfile
    }

    let claudeAiOauth: Data
    let profile: OAuthProfile

    init(claudeAiOauth: Data, profile: OAuthProfile) {
        self.claudeAiOauth = claudeAiOauth
        self.profile = profile
    }

    init(decoding data: Data) throws {
        let object = try Envelope(data)
        claudeAiOauth = try object.claudeAiOauth()
        guard let rawProfile = object.member("oauthAccount") else { throw Failure.missingProfile }
        profile = OAuthProfile(fields: try JSONDecoder().decode([String: AnyCodable].self, from: rawProfile))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data(#"{"claudeAiOauth":"#.utf8)
        out.append(claudeAiOauth)
        out.append(Data(#","oauthAccount":"#.utf8))
        out.append(try encoder.encode(profile.fields))
        out.append(Data("}".utf8))
        return out
    }

    /// The tokens in `claudeAiOauth`; throws if either is missing or empty.
    func login() throws -> OAuthLogin {
        try OAuthLogin(raw: claudeAiOauth)
    }
}
