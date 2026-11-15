import Foundation
import os
import Security

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "ClaudeItem")

/// Reads and writes Claude Code's own Keychain item.
protocol ClaudeItemAccess: Sendable {
    /// Reads the item through `/usr/bin/security`, which never prompts. For
    /// reads outside a switch's critical window.
    func read() throws -> Data
    /// Reads the item in-process and discards the data. The first in-process
    /// read shows the Keychain dialog; doing it before a switch starts keeps
    /// that dialog out of the window between the last read and the write.
    func preauthorize() throws
    /// Reads the item in-process and passes the bytes to `transform`, then
    /// writes what it returns (nothing when it returns nil). No process is
    /// spawned between the read and the write. Returns the bytes read.
    func update(_ transform: (Data) throws -> Data?) throws -> Data
    /// Throws `notUnique` unless exactly one item matches Claude's service and
    /// account across the keychain search list, and it is in the pinned
    /// keychain. Reads attributes only, so it never prompts.
    func requireUnique() throws
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

/// The keychain every Keychain call goes to, resolved once: its path (for
/// `security`) and its ref (for the `SecItem` APIs).
///
/// `@unchecked Sendable`: both properties are immutable, and the Keychain
/// APIs that use `keychain` are thread-safe.
struct KeychainPin: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noDefaultKeychain(OSStatus)
        case noPath(OSStatus)
    }

    let keychain: SecKeychain
    let path: String

    init(_ keychain: SecKeychain) throws {
        self.keychain = keychain
        path = try Self.path(of: keychain)
    }

    /// The user's default keychain (normally the login keychain), where
    /// Claude Code's `security` calls put its item.
    static func userDefault() throws -> KeychainPin {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDomainDefault(.user, &keychain)
        guard status == errSecSuccess, let keychain else { throw Failure.noDefaultKeychain(status) }
        return try KeychainPin(keychain)
    }

    static func path(of keychain: SecKeychain) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        var length = UInt32(PATH_MAX)
        let status = SecKeychainGetPath(keychain, &length, &buffer)
        guard status == errSecSuccess else { throw Failure.noPath(status) }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `path` with symlinks resolved (`/var` → `/private/var`), for comparing.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Claude Code's Keychain item: service `Claude Code-credentials`, account
/// `NSUserName()`, in the user's default (file-based) keychain.
///
/// No secret ever goes in argv or the environment:
/// - `read`: `security find-generic-password -s … -a … -w <keychain>`. The
///   secret comes back on stdout. The item already trusts `/usr/bin/security`,
///   so these reads never prompt. Used for every read outside a switch's
///   critical window (menu status, usage, save, verify).
/// - `preauthorize` and `update`: in-process `SecItemCopyMatching`. Reading
///   the data needs the item's `decrypt` authorization, so the first one
///   shows the Keychain dialog. Writing the data with `SecItemUpdate` needs
///   only `encrypt`, which items created by `security` grant to every app
///   (see Deviation 14 in docs/FORK_SPEC.md), so the write itself never
///   prompts.
///
/// The item is never created or deleted. Claude Code owns its lifecycle.
///
/// `@unchecked Sendable`: every property is immutable after init, and the
/// Keychain APIs are thread-safe.
struct ClaudeItem: ClaudeItemAccess, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case notFound
        case securityFailed(status: Int32)
        case readFailed(status: OSStatus)
        case updateFailed(status: OSStatus)
        case searchFailed(status: OSStatus)
        case unreadableOutput
        /// The keychains holding a matching item (anything but exactly the
        /// pinned keychain), and the pinned keychain's path.
        case notUnique(found: [String], expected: String)
    }

    static let claudeService = "Claude Code-credentials"

    let service: String
    let account: String
    let keychain: KeychainPin
    /// The keychains `requireUnique` searches. nil means the user's keychain
    /// search list. Tests pass temp keychains so the user's list is never
    /// read or changed.
    let searchList: [SecKeychain]?
    let runner: SecurityRunning

    init(service: String = claudeService,
         account: String = NSUserName(),
         keychain: KeychainPin,
         searchList: [SecKeychain]? = nil,
         runner: SecurityRunning = SecurityTool()) {
        self.service = service
        self.account = account
        self.keychain = keychain
        self.searchList = searchList
        self.runner = runner
    }

    func read() throws -> Data {
        let arguments = ["find-generic-password", "-s", service, "-a", account, "-w", keychain.path]
        let result = try runner.run(arguments, stdin: nil)
        if result.status == 44 { throw Failure.notFound }  // errSecItemNotFound
        guard result.status == 0 else {
            log.error("find-generic-password exited with \(result.status, privacy: .public)")
            throw Failure.securityFailed(status: result.status)
        }
        return try Self.decodePassword(result.stdout)
    }

    func preauthorize() throws {
        _ = try readInProcess()
    }

    /// The final read and the write, back to back. Nothing in here may spawn
    /// a process (a static check enforces it): Claude Code can rotate its
    /// token at any moment, and every millisecond between the read and the
    /// write is a chance to overwrite the new token.
    func update(_ transform: (Data) throws -> Data?) throws -> Data {
        let current = try readInProcess()
        if let data = try transform(current) { try updateData(data) }
        return current
    }

    func requireUnique() throws {
        var query = itemQuery()
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var found: [String] = []
        switch status {
        case errSecSuccess:
            guard let items = result as? [AnyObject] else { throw Failure.searchFailed(status: errSecInternalError) }
            for object in items {
                guard CFGetTypeID(object) == SecKeychainItemGetTypeID() else {
                    throw Failure.searchFailed(status: errSecInternalError)
                }
                var holder: SecKeychain?
                let copied = SecKeychainItemCopyKeychain(object as! SecKeychainItem, &holder)  // type checked above
                guard copied == errSecSuccess, let holder else { throw Failure.searchFailed(status: copied) }
                found.append(try KeychainPin.path(of: holder))
            }
        case errSecItemNotFound:
            break
        default:
            throw Failure.searchFailed(status: status)
        }
        guard found.count == 1, KeychainPin.canonical(found[0]) == KeychainPin.canonical(keychain.path) else {
            throw Failure.notUnique(found: found, expected: keychain.path)
        }
    }

    private func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private func pinnedQuery() -> [String: Any] {
        var query = itemQuery()
        query[kSecMatchSearchList as String] = [keychain.keychain]
        return query
    }

    private func readInProcess() throws -> Data {
        var query = pinnedQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure.unreadableOutput }
            return data
        case errSecItemNotFound:
            throw Failure.notFound
        default:
            // errSecUserCanceled / errSecAuthFailed land here when the user
            // declines the Keychain dialog.
            log.error("SecItemCopyMatching failed with \(status, privacy: .public)")
            throw Failure.readFailed(status: status)
        }
    }

    /// Replaces the item's data in place. Throws `.notFound` rather than
    /// creating an item if Claude Code's item is missing.
    private func updateData(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(pinnedQuery() as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw Failure.notFound
        default:
            log.error("SecItemUpdate failed with \(status, privacy: .public)")
            throw Failure.updateFailed(status: status)
        }
    }

    /// `security … -w` prints the password followed by a newline. When the
    /// password isn't printable ASCII (for example, it contains non-ASCII
    /// text), it prints the bytes as hex instead. Envelopes are JSON objects,
    /// so raw output starts with `{` (after any JSON whitespace) and hex
    /// output never does.
    static func decodePassword(_ output: Data) throws -> Data {
        var bytes = output
        if bytes.last == 0x0A { bytes.removeLast() }
        if Self.startsWithObject(bytes) { return bytes }
        guard let decoded = Data(hexString: bytes), Self.startsWithObject(decoded) else {
            throw Failure.unreadableOutput
        }
        return decoded
    }

    private static func startsWithObject(_ bytes: Data) -> Bool {
        bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } == UInt8(ascii: "{")
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
