import XCTest

/// Checks over the source tree for rules a code review could miss.
final class StaticChecksTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func sources() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                                      includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5)
        return files
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func configFiles() throws -> [URL] {
        var files = [root.appendingPathComponent("project.yml")]
        let workflows = root.appendingPathComponent(".github/workflows")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: workflows.path) {
            files += names.filter { $0.hasSuffix(".yml") }.map { workflows.appendingPathComponent($0) }
        }
        return files
    }

    /// No employer name anywhere in the repo's text files. The needle is
    /// split so this file doesn't match itself.
    func testNoEmployerName() throws {
        let needle = "ky" + "zen"
        let skip: Set<String> = [".git", "build", "CCSwitcher.xcodeproj", ".w"]
        let textExtensions: Set<String> = ["swift", "md", "yml", "yaml", "json", "plist", "txt", "sh", ""]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var checked = 0
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard textExtensions.contains(url.pathExtension),
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == false else { continue }
            checked += 1
            XCTAssertNil(try text(url).range(of: needle, options: .caseInsensitive), url.path)
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testURLSessionOnlyInUsageClient() throws {
        let users = try sources().filter { try text($0).contains("URLSession") }.map(\.lastPathComponent)
        XCTAssertEqual(users, ["UsageClient.swift"])
    }

    func testTheOnlyURLsAreTheUsageAndProfileEndpoints() throws {
        let pattern = try NSRegularExpression(pattern: #"https?://[^\s"'`)]+"#)
        var urls = Set<String>()
        for file in try sources() {
            let content = try text(file)
            for match in pattern.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                urls.insert(String(content[Range(match.range, in: content)!]))
            }
        }
        XCTAssertEqual(urls, ["https://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com/api/oauth/profile"])
    }

    private func body(of signature: String, in content: String) throws -> String {
        let start = try XCTUnwrap(content.range(of: signature), signature)
        let end = try XCTUnwrap(content.range(of: "\n    }\n", range: start.upperBound..<content.endIndex))
        return String(content[start.lowerBound..<end.upperBound])
    }

    func testClaudeItemWriteNeverUsesPasswordArgument() throws {
        let content = try text(root.appendingPathComponent("Sources/Keychain/ClaudeItem.swift"))
        let write = try body(of: "    private func updateData(_ data: Data) throws {", in: content)
        // Writes go through SecItemUpdate, never through a `security` process.
        XCTAssertTrue(write.contains("SecItemUpdate("))
        XCTAssertFalse(write.contains("runner"))
        XCTAssertFalse(write.contains(#""-w""#))

        // The final read and the write run back to back in-process: nothing
        // between them may spawn a process.
        let update = try body(of: "    func update(_ transform: (Data) throws -> Data?) throws -> Data {", in: content)
        XCTAssertTrue(update.contains("readInProcess()"))
        XCTAssertTrue(update.contains("updateData("))
        let read = try body(of: "    private func readInProcess() throws -> Data {", in: content)
        XCTAssertTrue(read.contains("SecItemCopyMatching("))
        for part in [update, read, write] {
            for spawn in [#"\brunner\b"#, #"\bProcess\b"#, #"/usr/bin/security"#] {
                XCTAssertNil(part.range(of: spawn, options: .regularExpression), "\(spawn) in the critical window")
            }
        }
        // The item is never created or deleted, and no other write path exists.
        for banned in ["add-generic-password", "delete-generic-password", "SecItemAdd", "SecItemDelete", #""-i""#, #""-X""#] {
            XCTAssertFalse(content.contains(banned), banned)
        }
        // "-w" appears only once: in the read.
        XCTAssertEqual(content.components(separatedBy: #""-w""#).count - 1, 1)
    }

    func testBannedStrings() throws {
        let banned = ["oauth/token", "Sparkle", "Aptabase", "GRDB", "FileLog",
                      "Timer", "didWakeNotification", "CFBundleURLTypes", "WidgetKit", "AppIntents", "zsh"]
        for file in try sources() + configFiles() {
            let content = try text(file)
            for word in banned {
                XCTAssertFalse(content.contains(word), "\(word) in \(file.lastPathComponent)")
            }
        }
    }

    func testNoSecretsInLogOrProcessEnvironment() throws {
        for file in try sources() {
            let content = try text(file)
            for pattern in [#"\bprint\("#, #"\bNSLog\("#, #"\bdebugPrint\("#] {
                XCTAssertNil(content.range(of: pattern, options: .regularExpression), "\(pattern) in \(file.lastPathComponent)")
            }
            // Only the login runner sets a child's environment, and only to
            // the allowlisted one it was given.
            let environmentLines = content.components(separatedBy: "\n")
                .filter { $0.range(of: #"\.environment\b"#, options: .regularExpression) != nil }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if file.lastPathComponent == "LoginRunner.swift" {
                XCTAssertEqual(environmentLines, ["process.environment = command.environment"])
            } else {
                XCTAssertEqual(environmentLines, [], file.lastPathComponent)
            }
        }
    }

    /// Processes are started in two places only: `security` (SecurityTool in
    /// ClaudeItem.swift) and the Add account login runner.
    func testProcessOnlyWhereNeeded() throws {
        var users: Set<String> = []
        for file in try sources() {
            let content = try text(file)
            if content.range(of: #"\bProcess\b"#, options: .regularExpression) != nil {
                users.insert(file.lastPathComponent)
            }
            for spawn in [#"\bNSTask\b"#, #"\bposix_spawn"#, #"\bpopen\("#, #"\bsystem\("#, #"\bexecv"#, #"\bfork\("#] {
                XCTAssertNil(content.range(of: spawn, options: .regularExpression), "\(spawn) in \(file.lastPathComponent)")
            }
        }
        XCTAssertEqual(users, ["ClaudeItem.swift", "LoginRunner.swift"])
    }

    /// The login runner runs the resolved `claude` directly: no shell, no
    /// PATH search, nothing read from the app's own environment, and no
    /// browser override.
    func testLoginRunnerRunsNoShellAndPassesNoBrowser() throws {
        let content = try text(root.appendingPathComponent("Sources/LoginRunner.swift"))
        for banned in ["/bin/sh", "bash", "/bin/zsh", "-lc", "-ilc", #""-c""#, "/usr/bin/env", "ProcessInfo",
                       "getenv", "launchPath", "which"] {
            XCTAssertFalse(content.contains(banned), banned)
        }
        XCTAssertNil(content.range(of: #"\benviron\b"#, options: .regularExpression))
        XCTAssertTrue(content.contains("guard let executable = command.argv.first"))
        XCTAssertTrue(content.contains("process.executableURL = URL(fileURLWithPath: executable)"))
        XCTAssertTrue(content.contains("process.arguments = Array(command.argv.dropFirst())"))
        XCTAssertTrue(content.contains("process.standardInput = FileHandle.nullDevice"))
        XCTAssertEqual(content.components(separatedBy: "executableURL").count - 1, 1)
        // Nothing in the app names the variable that redirects the browser.
        for file in try sources() {
            XCTAssertFalse(try text(file).contains("BROWSER"), file.lastPathComponent)
        }
    }
}
