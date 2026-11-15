import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "ClaudeItem")

/// Reads and writes Claude Code's own Keychain item.
protocol ClaudeItemAccess: Sendable {
    func read() throws -> Data
    func write(_ data: Data) throws
    /// Whether `write` can send `data` at all (see `ClaudeItem.maxCommandBytes`).
    func canWrite(_ data: Data) -> Bool
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
/// `NSUserName()`, in the default keychain.
///
/// No secret ever goes in argv or the environment:
/// - read: `security find-generic-password -s … -a … -w`; the secret comes
///   back on stdout.
/// - write: `security -i`, with `add-generic-password -U … -X <hex>` sent on
///   stdin.
/// The item is never deleted.
struct ClaudeItem: ClaudeItemAccess {
    enum Failure: Error, Equatable {
        case invalidName(String)
        case notFound
        /// The `security -i` command line would be longer than it can read.
        case tooLarge(bytes: Int)
        case securityFailed(status: Int32)
        case unreadableOutput
    }

    static let claudeService = "Claude Code-credentials"

    /// `security -i` reads its input in 4096-byte chunks and runs whatever
    /// doesn't fit as a separate command. A cut-off `add-generic-password`
    /// line still runs: it drops the trailing keychain argument and writes a
    /// truncated password to the default keychain. Lines are capped well under
    /// that limit, and anything longer is refused before `security` starts.
    static let maxCommandBytes = 4000

    let service: String
    let account: String
    /// Tests aim the item at a temporary keychain. Production passes nil, so
    /// `security` uses the default keychain, as Claude Code does.
    let keychainPath: String?
    let runner: SecurityRunning

    init(service: String = claudeService,
         account: String = NSUserName(),
         keychainPath: String? = nil,
         runner: SecurityRunning = SecurityTool()) {
        self.service = service
        self.account = account
        self.keychainPath = keychainPath
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

    func write(_ data: Data) throws {
        let line = try command(for: data)
        let result = try runner.run(["-i"], stdin: Data((line + "\n").utf8))
        // Never log stderr here: an error message from `security` may echo
        // the command line, which holds the hex-encoded secret.
        guard result.status == 0, result.stderr.isEmpty else {
            log.error("security -i exited with \(result.status, privacy: .public), stderr \(result.stderr.count, privacy: .public) bytes")
            throw Failure.securityFailed(status: result.status)
        }
    }

    func canWrite(_ data: Data) -> Bool {
        (try? command(for: data)) != nil
    }

    /// The single `security -i` command that writes `data`.
    private func command(for data: Data) throws -> String {
        guard Self.isSafe(service, allowing: " ") else { throw Failure.invalidName(service) }
        guard Self.isSafe(account) else { throw Failure.invalidName(account) }
        var line = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -X \(data.hexString)"
        if let keychainPath {
            guard keychainPath.hasPrefix("/"), Self.isSafe(keychainPath, allowing: "/") else {
                throw Failure.invalidName(keychainPath)
            }
            line += " \"\(keychainPath)\""
        }
        guard line.utf8.count + 1 <= Self.maxCommandBytes else {
            throw Failure.tooLarge(bytes: line.utf8.count + 1)
        }
        return line
    }

    /// `^[A-Za-z0-9._-]+$`, plus the characters in `extra`.
    private static func isSafe(_ value: String, allowing extra: String = "") -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" + extra)
        return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
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
