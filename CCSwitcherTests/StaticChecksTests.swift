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
            for pattern in [#"\.environment\b"#, #"\bprint\("#, #"\bNSLog\("#, #"\bdebugPrint\("#] {
                XCTAssertNil(content.range(of: pattern, options: .regularExpression), "\(pattern) in \(file.lastPathComponent)")
            }
        }
    }
}
