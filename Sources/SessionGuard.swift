import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "SessionGuard")

/// A Claude Code process that may keep using the old login after a switch.
struct LiveSession: Equatable, Sendable {
    let pid: Int32
    /// The session's working directory, or the executable path.
    let detail: String
    /// When the process started, or nil when it can't be read. Claude Code
    /// loads its login at startup, so this tells which account it got.
    var startedAt: Date? = nil
}

/// Start times of running processes. A protocol so tests use fakes.
protocol ProcessStartTimes: Sendable {
    func startTime(of pid: Int32) -> Date?
}

/// Start times from `proc_pidinfo(PROC_PIDTBSDINFO)`. Reads kernel process
/// info only; spawns nothing.
struct LibprocStartTimes: ProcessStartTimes {
    func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}

protocol SessionListing: Sendable {
    func liveSessions() -> [LiveSession]
}

/// Finds running Claude Code processes: those whose executable is named
/// `claude`, plus the live PIDs listed in `~/.claude/sessions/*.json`.
struct SessionGuard: SessionListing {
    let sessionsDirectory: URL
    /// Running processes. Injectable for tests.
    let processes: @Sendable () -> [RunningProcess]
    let isAlive: @Sendable (Int32) -> Bool
    let startTimes: ProcessStartTimes

    init(sessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions"),
         processes: @escaping @Sendable () -> [RunningProcess] = SessionGuard.runningProcesses,
         isAlive: @escaping @Sendable (Int32) -> Bool = SessionGuard.isProcessAlive,
         startTimes: ProcessStartTimes = LibprocStartTimes()) {
        self.sessionsDirectory = sessionsDirectory
        self.processes = processes
        self.isAlive = isAlive
        self.startTimes = startTimes
    }

    func liveSessions() -> [LiveSession] {
        var found: [Int32: LiveSession] = [:]
        let me = getpid()
        for process in processes() where process.pid != me && process.isClaude {
            found[process.pid] = LiveSession(pid: process.pid, detail: process.path)
        }
        for session in sessionFiles() where isAlive(session.pid) {
            found[session.pid] = LiveSession(pid: session.pid, detail: session.cwd ?? found[session.pid]?.detail ?? "")
        }
        return found.values.sorted { $0.pid < $1.pid }.map { session in
            var session = session
            session.startedAt = startTimes.startTime(of: session.pid)
            return session
        }
    }

    private struct SessionFile: Decodable {
        let pid: Int32
        let cwd: String?
    }

    private func sessionFiles() -> [SessionFile] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []  // Claude Code has never run a session here.
        } catch {
            log.error("Can't list sessions directory: \(String(describing: error), privacy: .public)")
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            // A file Claude Code is midway through writing, or an older
            // format, can't name a PID; the process scan still covers it.
            guard let data = FileManager.default.contents(atPath: url.path),
                  let file = try? JSONDecoder().decode(SessionFile.self, from: data) else { return nil }
            return file
        }
    }

    @Sendable static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Every process on the system, via libproc. Processes whose path we may
    /// not read (other users') are skipped.
    @Sendable static func runningProcesses() -> [RunningProcess] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            let hasName = proc_name(pid, &name, UInt32(name.count)) > 0
            return RunningProcess(pid: pid, name: hasName ? Self.string(name) : "", path: Self.string(buffer))
        }
    }
}

extension SessionGuard {
    /// A NUL-terminated C buffer as a String.
    fileprivate static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct RunningProcess: Sendable {
    let pid: Int32
    /// The name the process was started under (`p_comm`).
    let name: String
    let path: String

    /// Claude Code's native installer starts a versioned binary through a
    /// `claude` symlink, so the start name counts as well as the path.
    var isClaude: Bool {
        (path as NSString).lastPathComponent == "claude" || name == "claude"
    }
}
