import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "ClaudeConfig")

/// Reads and writes the `oauthAccount` block of `~/.claude.json`.
protocol ClaudeProfileAccess: Sendable {
    func readProfile() throws -> OAuthProfile
    func writeProfile(_ profile: OAuthProfile) throws
}

/// `~/.claude.json`, the file Claude Code keeps most of its settings in. Only
/// `oauthAccount` may change.
struct ClaudeConfig: ClaudeProfileAccess {
    enum Failure: Error, Equatable {
        case unreadable
        case noOAuthAccount
        case writeFailed(errno: Int32)
        case keptChanging
    }

    let path: String

    init(path: String = NSHomeDirectory() + "/.claude.json") {
        self.path = path
    }

    func readProfile() throws -> OAuthProfile {
        let json = try readJSON(at: path)
        guard let block = json["oauthAccount"]?.value as? [String: AnyCodable] else {
            throw Failure.noOAuthAccount
        }
        return OAuthProfile(fields: block)
    }

    /// Replaces `oauthAccount` and keeps every other key.
    ///
    /// Writes to the file the path points at: dotfile managers symlink
    /// `~/.claude.json`, and replacing the link with a plain file would fork
    /// the user's config. The replace is atomic (temp file plus rename) and
    /// keeps the file's permissions, since it holds MCP server settings and is
    /// usually 0600.
    ///
    /// Claude Code rewrites this file on its own. If it changes between our
    /// read and our rename, start over from its version, up to 3 times.
    func writeProfile(_ profile: OAuthProfile) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for attempt in 1...3 {
            let before = try Self.fingerprint(target)
            let json = try readJSON(at: target)
            let newData = try Self.claudeJSON(json, replacingOAuthAccount: profile.fields)
            let tmp = (target as NSString).deletingLastPathComponent + "/.claude.json.ccswitcher-\(UUID().uuidString)"
            try Self.writeNewFile(tmp, newData, mode: before.mode)

            // Last check right before the rename, to keep the window in which
            // a write by Claude Code could be lost as small as possible.
            guard try Self.fingerprint(target) == before else {
                unlink(tmp)
                log.notice("~/.claude.json changed during write (attempt \(attempt, privacy: .public)); retrying")
                continue
            }
            guard rename(tmp, target) == 0 else {
                let code = errno
                unlink(tmp)
                throw Failure.writeFailed(errno: code)
            }
            return
        }
        throw Failure.keptChanging
    }

    /// The bytes `writeProfile` writes: `json` with its `oauthAccount` block
    /// replaced and every other key carried over.
    static func claudeJSON(_ json: [String: AnyCodable], replacingOAuthAccount oauthAccount: [String: AnyCodable]) throws -> Data {
        var json = json
        json["oauthAccount"] = AnyCodable(oauthAccount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }

    private func readJSON(at path: String) throws -> [String: AnyCodable] {
        guard let data = FileManager.default.contents(atPath: path) else { throw Failure.unreadable }
        return try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    /// Modification time (to the nanosecond), size and inode: if any of
    /// them changed, someone else wrote the file.
    private struct Fingerprint: Equatable {
        let seconds: Int, nanoseconds: Int, size: Int64, inode: UInt64
        let mode: mode_t
    }

    private static func fingerprint(_ path: String) throws -> Fingerprint {
        var info = stat()
        guard stat(path, &info) == 0 else { throw Failure.writeFailed(errno: errno) }
        return Fingerprint(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec,
                           size: info.st_size, inode: info.st_ino, mode: info.st_mode & 0o7777)
    }

    /// Creates `path` (which must not exist) readable only by the owner while
    /// it is written, then gives it the original file's permissions.
    private static func writeNewFile(_ path: String, _ data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed(errno: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard fchmod(fd, mode) == 0 else { throw Failure.writeFailed(errno: errno) }
            try handle.close()
        } catch {
            // Remove the partial file, then report the original error.
            unlink(path)
            throw error
        }
    }
}
