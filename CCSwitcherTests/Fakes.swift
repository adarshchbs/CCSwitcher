import Foundation

/// In-memory stand-ins for the Switcher's dependencies. Each one counts calls
/// and can be told to fail, so tests can drive every branch of a switch.

final class FakeItem: ClaudeItemAccess, @unchecked Sendable {
    private let lock = NSLock()
    var data: Data?
    var writes: [Data] = []
    var reads = 0
    /// Called with the read count before each read returns; may change `data`.
    var onRead: ((FakeItem, Int) -> Void)?
    /// Called with the write count; return an error to fail that write.
    var failWrite: ((Int) -> Error?)?
    /// Whether a write stores its data (false simulates a silent no-op).
    var writeTakesEffect: ((Int) -> Bool)?
    var maxBytes = Int.max

    init(_ data: Data?) { self.data = data }

    func read() throws -> Data {
        try lock.withLock {
            reads += 1
            onRead?(self, reads)
            guard let data else { throw ClaudeItem.Failure.notFound }
            return data
        }
    }

    func write(_ newData: Data) throws {
        try lock.withLock {
            writes.append(newData)
            if let error = failWrite?(writes.count) { throw error }
            if writeTakesEffect?(writes.count) ?? true { data = newData }
        }
    }

    func canWrite(_ data: Data) -> Bool { data.count <= maxBytes }
}

final class FakeStore: SavedLoginStore, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: Data] = [:]
    var failWrites = false
    var failDelete: Error?
    var writes = 0

    func read(id: String) throws -> Data {
        try lock.withLock {
            guard let data = items[id] else { throw AccountStore.Failure.notFound }
            return data
        }
    }

    func write(id: String, data: Data) throws {
        try lock.withLock {
            writes += 1
            if failWrites { throw AccountStore.Failure.status(-25293) }
            items[id] = data
        }
    }

    func delete(id: String) throws {
        try lock.withLock {
            if let failDelete { throw failDelete }
            guard items.removeValue(forKey: id) != nil else { throw AccountStore.Failure.notFound }
        }
    }
}

final class FakeConfig: ClaudeProfileAccess, @unchecked Sendable {
    private let lock = NSLock()
    var profile: OAuthProfile?
    var writes = 0
    var failWrite: ((Int) -> Error?)?

    init(_ profile: OAuthProfile?) { self.profile = profile }

    func readProfile() throws -> OAuthProfile {
        try lock.withLock {
            guard let profile else { throw ClaudeConfig.Failure.noOAuthAccount }
            return profile
        }
    }

    func writeProfile(_ newProfile: OAuthProfile) throws {
        try lock.withLock {
            writes += 1
            if let error = failWrite?(writes) { throw error }
            profile = newProfile
        }
    }
}

final class FakeAccounts: AccountList, @unchecked Sendable {
    private let lock = NSLock()
    var accounts: [SavedAccount]

    init(_ accounts: [SavedAccount]) { self.accounts = accounts }

    func load() throws -> [SavedAccount] { lock.withLock { accounts } }
    func save(_ accounts: [SavedAccount]) throws { lock.withLock { self.accounts = accounts } }
}

struct FakeSessions: SessionListing {
    var sessions: [LiveSession] = []
    func liveSessions() -> [LiveSession] { sessions }
}

struct TestFailure: Error {}

/// Lets a test hold an operation at its confirmation prompt.
actor Gate {
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Bool, Never>?

    func arrive() async -> Bool {
        arrived = true
        arrivalWaiter?.resume()
        return await withCheckedContinuation { release = $0 }
    }

    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func open(_ answer: Bool) {
        release?.resume(returning: answer)
    }
}

/// Test data: two logins that share one email address.
enum Fixture {
    static let team = SavedAccount(id: "team-id", label: "Team", email: "me@x.com", orgUuid: "org-team")
    static let personal = SavedAccount(id: "personal-id", label: "Personal", email: "me@x.com", orgUuid: "org-personal")

    static func oauth(_ name: String) -> Data {
        Data(#"{"accessToken":"\#(name)-access","refreshToken":"\#(name)-refresh","expiresAt":4102444800000,"subscriptionType":"team"}"#.utf8)
    }

    static func envelope(_ oauth: Data) -> Data {
        Data(#"{"mcpOAuth":{"server":{"accessToken":"mcp-secret"}},"claudeAiOauth":"#.utf8) + oauth + Data(#","other":[1,2]}"#.utf8)
    }

    static func profile(org: String, email: String = "me@x.com") -> OAuthProfile {
        OAuthProfile(fields: [
            "organizationUuid": AnyCodable(org),
            "emailAddress": AnyCodable(email),
            "organizationName": AnyCodable(org.uppercased()),
        ])
    }

    static func stored(_ name: String, org: String) throws -> Data {
        try StoredLogin(claudeAiOauth: oauth(name), profile: profile(org: org)).encoded()
    }
}
