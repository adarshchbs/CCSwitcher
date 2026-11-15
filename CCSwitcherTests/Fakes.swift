import Foundation

/// In-memory stand-ins for the Switcher's dependencies. Each one counts calls
/// and can be told to fail, so tests can drive every branch of a switch.

final class FakeItem: ClaudeItemAccess, @unchecked Sendable {
    private let lock = NSLock()
    var data: Data?
    var writes: [Data] = []
    /// Reads of every kind: `read()` and the in-process read in `update`.
    var reads = 0
    var preauthorizations = 0
    /// Called with the read count before each read returns; may change `data`.
    var onRead: ((FakeItem, Int) -> Void)?
    /// Called with the write count; return an error to fail that write.
    var failWrite: ((Int) -> Error?)?
    /// Whether a write stores its data (false simulates a silent no-op).
    var writeTakesEffect: ((Int) -> Bool)?
    /// Called after each write with the write count.
    var onWrite: ((FakeItem, Int) -> Void)?
    var preauthorizeError: Error?
    var uniqueError: Error?

    init(_ data: Data?) { self.data = data }

    func read() throws -> Data {
        try lock.withLock { try readLocked() }
    }

    func preauthorize() throws {
        try lock.withLock {
            preauthorizations += 1
            if let preauthorizeError { throw preauthorizeError }
            guard data != nil else { throw ClaudeItem.Failure.notFound }
        }
    }

    func update(_ transform: (Data) throws -> Data?) throws -> Data {
        try lock.withLock {
            let current = try readLocked()
            guard let newData = try transform(current) else { return current }
            writes.append(newData)
            if let error = failWrite?(writes.count) { throw error }
            if writeTakesEffect?(writes.count) ?? true { data = newData }
            onWrite?(self, writes.count)
            return current
        }
    }

    func requireUnique() throws {
        if let uniqueError { throw uniqueError }
    }

    private func readLocked() throws -> Data {
        reads += 1
        onRead?(self, reads)
        guard let data else { throw ClaudeItem.Failure.notFound }
        return data
    }
}

/// Answers the profile endpoint by access-token prefix (`"team"` →
/// `org-team`), and records every token it was sent.
final class FakeLookup: OrgLookup, @unchecked Sendable {
    private let lock = NSLock()
    var prefixes: [String: String]
    /// Overrides the table when set.
    var result: OrgLookupResult?
    private var _tokens: [String] = []

    init(_ prefixes: [String: String] = ["team": "org-team", "personal": "org-personal"]) {
        self.prefixes = prefixes
    }

    var tokens: [String] { lock.withLock { _tokens } }

    func organization(accessToken: String) async throws -> OrgLookupResult {
        lock.withLock {
            _tokens.append(accessToken)
            if let result { return result }
            guard let org = prefixes.first(where: { accessToken.hasPrefix($0.key) })?.value else {
                return .failed("unknown token")
            }
            return .organization(uuid: org, name: org.uppercased())
        }
    }
}

final class FakeJournal: SwitchJournal, @unchecked Sendable {
    private let lock = NSLock()
    var pending: PendingSwitch?
    var saves = 0

    func load() throws -> PendingSwitch? { lock.withLock { pending } }
    func save(_ pending: PendingSwitch) throws { lock.withLock { saves += 1; self.pending = pending } }
    func clear() { lock.withLock { pending = nil } }
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

/// Stands in for `claude auth login`. Records each command and runs
/// `onRun` in its place (to change the live login the way the CLI would), then
/// returns `end`. Never starts a process.
final class FakeLoginRunner: LoginRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [LoginCommand] = []
    private var _timeouts: [TimeInterval] = []
    var end: LoginEnd = .exited(0)
    var error: Error?
    var onRun: (@Sendable () async -> Void)?

    var commands: [LoginCommand] { lock.withLock { _commands } }
    var timeouts: [TimeInterval] { lock.withLock { _timeouts } }

    func run(_ command: LoginCommand, timeout: TimeInterval, cancellation: LoginCancellation) async throws -> LoginEnd {
        lock.withLock {
            _commands.append(command)
            _timeouts.append(timeout)
        }
        if let error { throw error }
        await onRun?()
        return end
    }
}

struct TestFailure: Error {}

/// A mutable cell that test closures can write to.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

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

    /// Fixed "now" for tests. `oauth` tokens expire in 2100 by default.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let expired: Int64 = 1_700_000_000_000

    static func oauth(_ name: String, expiresAt: Int64 = 4_102_444_800_000) -> Data {
        Data(#"{"accessToken":"\#(name)-access","refreshToken":"\#(name)-refresh","expiresAt":\#(expiresAt),"subscriptionType":"team"}"#.utf8)
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

    /// No `claude` anywhere: Add account fails before changing anything.
    static let noCLI = ClaudeCLI(candidates: [], environment: [:])

    static func stored(_ name: String, org: String) throws -> Data {
        try StoredLogin(claudeAiOauth: oauth(name), profile: profile(org: org)).encoded()
    }
}
