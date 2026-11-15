import Foundation
import Security
import XCTest

/// A keychain file in a fresh temp directory, deleted in teardown. Tests that
/// touch the Keychain use only this; they never use the login keychain.
final class TempKeychain {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccswitcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("test.keychain-db").path
        let password = UUID().uuidString
        try Self.security(["create-keychain", "-p", password, path])
        try Self.security(["unlock-keychain", "-p", password, path])
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

    func delete() throws {
        try Self.security(["delete-keychain", path])
        try FileManager.default.removeItem(at: directory)
    }

    private static func security(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "security", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "security \(arguments[0]) failed"])
        }
    }
}

/// Wraps the real `security` runner. Records every spawn, and refuses any
/// `security -i` command that isn't aimed at the temp keychain or that is long
/// enough for `security` to split. Either would write to the login keychain.
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
        if let stdin {
            let line = String(decoding: stdin, as: UTF8.self)
            precondition(stdin.count < 4096, "security -i would split this line")
            precondition(line.hasSuffix(" \"\(keychainPath)\"\n"), "write not aimed at the temp keychain")
        } else {
            precondition(arguments.last == keychainPath, "read not aimed at the temp keychain")
        }
        return try SecurityTool().run(arguments, stdin: stdin)
    }
}
