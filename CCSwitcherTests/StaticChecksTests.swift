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

    func testTheOnlyURLIsTheUsageEndpoint() throws {
        let pattern = try NSRegularExpression(pattern: #"https?://[^\s"'`)]+"#)
        var urls = Set<String>()
        for file in try sources() {
            let content = try text(file)
            for match in pattern.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                urls.insert(String(content[Range(match.range, in: content)!]))
            }
        }
        XCTAssertEqual(urls, ["https://api.anthropic.com/api/oauth/usage"])
    }

    func testClaudeItemWriteNeverUsesPasswordArgument() throws {
        let content = try text(root.appendingPathComponent("Sources/Keychain/ClaudeItem.swift"))
        let start = try XCTUnwrap(content.range(of: "    func write(_ data: Data) throws {"))
        let end = try XCTUnwrap(content.range(of: "\n    }\n", range: start.upperBound..<content.endIndex))
        let write = String(content[start.lowerBound..<end.upperBound])
        XCTAssertFalse(write.contains(#""-w""#))
        XCTAssertTrue(write.contains(#"["-i"]"#))

        // The command line is built in one place, with -X and no -w.
        let command = try XCTUnwrap(content.components(separatedBy: "\n").first { $0.contains("add-generic-password") && $0.contains("var line") })
        XCTAssertTrue(command.contains(" -X "))
        XCTAssertFalse(command.contains("-w"))
        XCTAssertFalse(content.contains("delete-generic-password"))
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
