import Foundation
import Security
import XCTest

/// A keychain file in a fresh temp directory, deleted in teardown. Tests that
/// touch the Keychain use only this; they never use the login keychain.
final class TempKeychain {
    let directory: URL
    let path: String
    private let password: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccswitcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("test.keychain-db").path
        password = UUID().uuidString
        try Self.security(["create-keychain", "-p", password, path])
        try Self.security(["unlock-keychain", "-p", password, path])
    }

    /// Creates a generic password the way Claude Code does, through
    /// `/usr/bin/security`, then opens it to both `security` and the test
    /// process. Without that, the first cross-tool access shows a Keychain
    /// password dialog and the test hangs until it times out. Test data only:
    /// `value` goes in argv here, which the app itself never does.
    func seedGenericPassword(service: String, account: String, value: String) throws {
        try Self.security(["add-generic-password", "-A", "-s", service, "-a", account, "-w", value, path])
        // `security` is `apple-tool:`, the Apple-signed xctest host is `apple:`.
        try Self.security(["set-generic-password-partition-list", "-S", "apple-tool:,apple:,unsigned:",
                           "-s", service, "-a", account, "-k", password, path], quiet: true)
    }

    /// The keychain's items with their access lists and partition IDs, minus
    /// modification times. No secrets: `dump-keychain` without `-d`.
    func accessControlDump() throws -> String {
        let result = try SecurityTool().run(["dump-keychain", "-a", path], stdin: nil)
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n").filter { !$0.contains("\"mdat\"") }.joined(separator: "\n")
    }

    /// The keychain as a `SecKeychain`, for the `SecItem` APIs.
    func open() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return keychain
    }

    func pin() throws -> KeychainPin {
        try KeychainPin(open())
    }

    func delete() throws {
        try Self.security(["delete-keychain", path])
        try FileManager.default.removeItem(at: directory)
    }

    private static func security(_ arguments: [String], quiet: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        // set-*-partition-list prints the item's attributes on success.
        if quiet { process.standardOutput = FileHandle.nullDevice }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "security", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "security \(arguments[0]) failed"])
        }
    }
}

/// Wraps the real `security` runner. Records every spawn, and refuses anything
/// that isn't a read aimed at the temp keychain. `ClaudeItem` only reads
/// through `security`; a spawn with stdin means a write path crept back in.
final class GuardedRunner: SecurityRunning, @unchecked Sendable {
    private let keychainPath: String
    private let lock = NSLock()
    private var _calls: [(arguments: [String], stdin: Data?)] = []

    init(keychainPath: String) { self.keychainPath = keychainPath }

    var calls: [(arguments: [String], stdin: Data?)] {
        lock.withLock { _calls }
    }

    func run(_ arguments: [String], stdin: Data?) throws -> SecurityResult {
        lock.withLock { _calls.append((arguments, stdin)) }
        precondition(stdin == nil, "ClaudeItem must not write through security")
        precondition(arguments.first == "find-generic-password", "only reads go through security")
        precondition(arguments.last == keychainPath, "read not aimed at the temp keychain")
        return try SecurityTool().run(arguments, stdin: nil)
    }
}
