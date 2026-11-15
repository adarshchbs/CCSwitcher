import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "LoginRunner")

/// The `claude auth login --claudeai` command Add account runs: the argv
/// (the resolved executable first) and the whole environment the child gets.
/// No secret goes in either.
struct LoginCommand: Equatable, Sendable {
    let argv: [String]
    let environment: [String: String]
}

/// How a login run ended.
enum LoginEnd: Equatable, Sendable {
    /// The process exited on its own, with this status (or signal number).
    case exited(Int32)
    /// The user chose "Cancel sign-in"; the process was terminated.
    case cancelled
    /// The time limit passed; the process was terminated.
    case timedOut
}

/// Runs the login command and returns when it ends. A protocol so tests never
/// run the real `claude`.
protocol LoginRunning: Sendable {
    /// Throws only when the process can't be started.
    func run(_ command: LoginCommand, timeout: TimeInterval, cancellation: LoginCancellation) async throws -> LoginEnd
}

/// "Cancel sign-in". Thread-safe; cancelling before the run starts makes the
/// run end at once without starting a process.
final class LoginCancellation: @unchecked Sendable {
    // `@unchecked Sendable`: all state is guarded by `lock`.
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let run: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { handler = nil }
            return handler
        }
        run?()
    }

    /// Calls `handler` on cancel, or right away if already cancelled.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            if cancelled { return true }
            self.handler = handler
            return false
        }
        if runNow { handler() }
    }
}

/// Finds Claude Code's CLI and builds the login command.
///
/// - Executable: the first executable file among fixed candidates, with
///   symlinks resolved. No shell, no PATH search.
/// - Environment: built from scratch from an allowlist (`HOME`, `USER`,
///   `LOGNAME`, `LANG`, `TMPDIR`, and a fixed system `PATH`). Nothing is
///   copied from the app's own environment, so no browser override or other
///   variable reaches the child. The CLI opens the default browser itself.
struct ClaudeCLI: Sendable {
    static let loginArguments = ["auth", "login", "--claudeai"]
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let timeout: TimeInterval = 600

    let candidates: [String]
    let environment: [String: String]

    /// `~/.local/bin/claude` (the native installer), then Homebrew's two
    /// prefixes.
    static func standard() -> ClaudeCLI {
        let home = NSHomeDirectory()
        return ClaudeCLI(
            candidates: [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            environment: loginEnvironment(home: home, user: NSUserName(), temporaryDirectory: NSTemporaryDirectory()))
    }

    static func loginEnvironment(home: String, user: String, temporaryDirectory: String) -> [String: String] {
        [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "LANG": "en_US.UTF-8",
            "TMPDIR": temporaryDirectory,
            "PATH": systemPath,
        ]
    }

    enum Failure: Error, Equatable {
        case notFound(searched: [String])
    }

    /// The first candidate that is an executable file, symlinks resolved.
    func resolve() throws -> String {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard FileManager.default.isExecutableFile(atPath: resolved) else { continue }
            log.info("Using claude at \(resolved, privacy: .public)")
            return resolved
        }
        throw Failure.notFound(searched: candidates)
    }

    func loginCommand() throws -> LoginCommand {
        LoginCommand(argv: [try resolve()] + Self.loginArguments, environment: environment)
    }
}

/// Runs the login command as a child process: no shell, stdin from
/// `/dev/null`, the given environment only. Its stdout and stderr can carry
/// sign-in URLs and codes, so they are drained and dropped as they arrive,
/// never stored, logged or shown; only the exit matters.
struct ProcessLoginRunner: LoginRunning {
    func run(_ command: LoginCommand, timeout: TimeInterval, cancellation: LoginCancellation) async throws -> LoginEnd {
        guard let executable = command.argv.first else { throw ClaudeCLI.Failure.notFound(searched: []) }
        if cancellation.isCancelled { return .cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.argv.dropFirst())
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        let pipes = [Pipe(), Pipe()]
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                // Drop the bytes. Empty data means end of file.
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
        }
        let run = RunningLogin(process)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: run.end(status: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                log.error("Couldn't start claude: \(String(describing: error), privacy: .public)")
                continuation.resume(throwing: error)
                return
            }
            log.info("Waiting for sign-in (pid \(process.processIdentifier, privacy: .public))")
            cancellation.onCancel { run.stop(.cancelled) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { run.stop(.timedOut) }
        }
    }
}

/// The running child and why it was stopped, if it was.
private final class RunningLogin: @unchecked Sendable {
    // `@unchecked Sendable`: `reason` is guarded by `lock`; `Process` is
    // only asked whether it runs, and signalled.
    private let lock = NSLock()
    private let process: Process
    private var reason: LoginEnd?

    init(_ process: Process) { self.process = process }

    func end(status: Int32) -> LoginEnd {
        lock.withLock { reason ?? .exited(status) }
    }

    /// SIGTERM, then SIGKILL if it's still running 5 s later.
    func stop(_ why: LoginEnd) {
        let stopping = lock.withLock {
            guard reason == nil, process.isRunning else { return false }
            reason = why
            return true
        }
        guard stopping else { return }
        log.notice("Stopping sign-in: \(String(describing: why), privacy: .public)")
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
