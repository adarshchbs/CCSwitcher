import Foundation
import os
import Security

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "ClaudeItem")

/// Reads and writes Claude Code's own Keychain item.
protocol ClaudeItemAccess: Sendable {
    func read() throws -> Data
    func write(_ data: Data) throws
}

/// Runs `/usr/bin/security`. A protocol so tests can record what gets spawned.
protocol SecurityRunning: Sendable {
    func run(_ arguments: [String], stdin: Data?) throws -> SecurityResult
}

struct SecurityResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Claude Code's Keychain item: service `Claude Code-credentials`, account
/// `NSUserName()`, in the file-based login keychain.
///
/// No secret ever goes in argv or the environment:
/// - read: `security find-generic-password -s … -a … -w`. The secret comes
///   back on stdout. Going through `/usr/bin/security`, which the item already
///   trusts, means reads never trigger a Keychain prompt.
/// - write: `SecItemUpdate` on the existing item, data only. The first write
///   asks the user to let this app change the item; approving adds the app to
///   the item's access list and leaves every existing entry in place.
///
/// The item is never created or deleted. Claude Code owns its lifecycle.
///
/// `@unchecked Sendable`: every property is immutable after init, and the
/// Keychain APIs that use `keychain` are thread-safe.
struct ClaudeItem: ClaudeItemAccess, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case notFound
        case securityFailed(status: Int32)
        case updateFailed(status: OSStatus)
        case unreadableOutput
    }

    static let claudeService = "Claude Code-credentials"

    let service: String
    let account: String
    /// Tests aim the item at a temporary keychain, given both as a path (for
    /// `security`) and as a `SecKeychain` (for `SecItemUpdate`). Production
    /// passes nil for both and uses the default keychain, as Claude Code does.
    let keychainPath: String?
    let keychain: SecKeychain?
    let runner: SecurityRunning

    init(service: String = claudeService,
         account: String = NSUserName(),
         keychainPath: String? = nil,
         keychain: SecKeychain? = nil,
         runner: SecurityRunning = SecurityTool()) {
        precondition((keychainPath == nil) == (keychain == nil),
                     "keychainPath and keychain must name the same keychain")
        self.service = service
        self.account = account
        self.keychainPath = keychainPath
        self.keychain = keychain
        self.runner = runner
    }

    func read() throws -> Data {
        var arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        if let keychainPath { arguments.append(keychainPath) }
        let result = try runner.run(arguments, stdin: nil)
        if result.status == 44 { throw Failure.notFound }  // errSecItemNotFound
        guard result.status == 0 else {
            log.error("find-generic-password exited with \(result.status, privacy: .public)")
            throw Failure.securityFailed(status: result.status)
        }
        return try Self.decodePassword(result.stdout)
    }

    /// Replaces the item's data in place. Throws `.notFound` rather than
    /// creating an item if Claude Code's item is missing.
    func write(_ data: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw Failure.notFound
        default:
            // errSecUserCanceled / errSecAuthFailed land here when the user
            // declines the Keychain prompt. Nothing was written.
            log.error("SecItemUpdate failed with \(status, privacy: .public)")
            throw Failure.updateFailed(status: status)
        }
    }

    /// `security … -w` prints the password followed by a newline. When the
    /// password isn't printable ASCII (for example, it contains non-ASCII
    /// text), it prints the bytes as hex instead. Envelopes are JSON objects,
    /// so raw output starts with `{` and hex output never does.
    static func decodePassword(_ output: Data) throws -> Data {
        var bytes = output
        if bytes.last == 0x0A { bytes.removeLast() }
        if bytes.first == UInt8(ascii: "{") { return bytes }
        guard let decoded = Data(hexString: bytes), decoded.first == UInt8(ascii: "{") else {
            throw Failure.unreadableOutput
        }
        return decoded
    }
}

/// Spawns `/usr/bin/security` directly: no shell, and an environment
/// inherited unchanged from the app.
struct SecurityTool: SecurityRunning {
    func run(_ arguments: [String], stdin: Data?) throws -> SecurityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let stdin {
            // If `security` exits early, fail the write with EPIPE instead of
            // killing the app with SIGPIPE.
            let writer = stdinPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try writer.write(contentsOf: stdin)
            try writer.close()
        }
        // Drain stderr on another thread so neither pipe can fill and stall
        // the child while we read the other one.
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return SecurityResult(status: process.terminationStatus, stdout: out, stderr: stderrBox.data)
    }
}

/// Carries stderr bytes back from the reader thread. Written once before
/// `group.leave()` and read after `group.wait()`, so access is ordered.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString hex: Data) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var high: UInt8?
        for byte in hex {
            let nibble: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high { out.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        self = out
    }
}
