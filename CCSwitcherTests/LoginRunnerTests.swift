import XCTest

/// `ProcessLoginRunner` with harmless system binaries in place of `claude`.
/// The real CLI is never run.
final class LoginRunnerTests: XCTestCase {
    private let runner = ProcessLoginRunner()
    private let environment = ClaudeCLI.loginEnvironment(home: "/h", user: "u", temporaryDirectory: NSTemporaryDirectory())

    private func run(_ argv: [String], timeout: TimeInterval = 30,
                     cancellation: LoginCancellation = LoginCancellation()) async throws -> LoginEnd {
        try await runner.run(LoginCommand(argv: argv, environment: environment), timeout: timeout, cancellation: cancellation)
    }

    func testReportsTheExitStatus() async throws {
        let ok = try await run(["/usr/bin/true"])
        XCTAssertEqual(ok, .exited(0))
        let failed = try await run(["/usr/bin/false"])
        XCTAssertEqual(failed, .exited(1))
    }

    func testCancelTerminatesTheProcess() async throws {
        let cancellation = LoginCancellation()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let end = try await run(["/bin/sleep", "30"], cancellation: cancellation)
        XCTAssertEqual(end, .cancelled)
        // `run` returns only once the process has exited.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTimeoutTerminatesTheProcess() async throws {
        let started = Date()
        let end = try await run(["/bin/sleep", "30"], timeout: 0.3)
        XCTAssertEqual(end, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancelledBeforeTheStartSpawnsNothing() async throws {
        let cancellation = LoginCancellation()
        cancellation.cancel()
        // A path that can't be run: reaching `Process.run` would throw.
        let end = try await run(["/nonexistent/claude", "auth", "login", "--claudeai"], cancellation: cancellation)
        XCTAssertEqual(end, .cancelled)
    }

    func testAnExecutableThatCantStartThrows() async throws {
        do {
            _ = try await run(["/nonexistent/claude"])
            XCTFail("expected a launch failure")
        } catch is CocoaError {
            // expected
        }
    }

    /// The child sees only the allowlisted environment: nothing from the
    /// test process (even a browser override set there) leaks through.
    func testChildGetsOnlyTheGivenEnvironment() async throws {
        setenv("BROWSER", "/tmp/evil-browser", 1)
        setenv("CCSWITCHER_LEAK_CHECK", "leak", 1)
        defer {
            unsetenv("BROWSER")
            unsetenv("CCSWITCHER_LEAK_CHECK")
        }
        let script = #"""
            [ -z "${BROWSER+x}" ] && [ -z "${CCSWITCHER_LEAK_CHECK+x}" ] \
              && [ "$PATH" = "/usr/bin:/bin:/usr/sbin:/sbin" ] && [ "$HOME" = "/h" ] \
              && [ "$USER" = "u" ] && [ "$LOGNAME" = "u" ] && [ "$LANG" = "en_US.UTF-8" ]
            """#
        let end = try await run(["/bin/sh", "-c", script])
        XCTAssertEqual(end, .exited(0))
    }

    func testStdinIsEmpty() async throws {
        let end = try await run(["/bin/sh", "-c", "if read -r line; then exit 9; fi; exit 0"])
        XCTAssertEqual(end, .exited(0))
    }

    /// Lots of output on both streams can't stall the child: the runner
    /// drains and drops it.
    func testLargeOutputDoesNotBlock() async throws {
        let end = try await run(["/bin/sh", "-c", "yes | head -c 2000000; yes | head -c 2000000 1>&2"], timeout: 20)
        XCTAssertEqual(end, .exited(0))
    }
}
