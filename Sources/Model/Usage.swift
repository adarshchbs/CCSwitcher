import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Usage")

// MARK: - API response

/// The parts of `GET /api/oauth/usage` the app shows. Decoding is lenient:
/// unknown fields are ignored, a `limits` item that doesn't decode is
/// skipped, and a missing `limits` falls back to `five_hour`/`seven_day`.
struct UsageAPIResponse: Decodable {
    let limits: [APILimit]?
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each member is optional on its own: one with an unexpected shape
        // must not hide the others.
        limits = (try? container.decodeIfPresent(LenientArray<APILimit>.self, forKey: .limits))?.elements
        fiveHour = try? container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try? container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
    }
}

/// An array whose elements that don't decode are dropped (and counted in
/// the log), instead of failing the whole array.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                skipped += 1
                _ = try container.decode(Skip.self)
            }
        }
        if skipped > 0 { log.notice("Skipped \(skipped, privacy: .public) usage limits that didn't decode") }
        self.elements = elements
    }

    /// Consumes one element of any shape.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// One item of `limits`. Every field is optional; one of the wrong type
/// reads as missing.
struct APILimit: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Name?
        let surface: Name?
    }

    /// A display name given as a string or as an object with
    /// `display_name`, `name` or `id`.
    struct Name: Decodable {
        let value: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case name, id
        }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                value = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = [CodingKeys.displayName, .name, .id].lazy
                .compactMap { try? container.decodeIfPresent(String.self, forKey: $0) }
                .first { !$0.isEmpty }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
        percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
        severity = try? container.decodeIfPresent(String.self, forKey: .severity)
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
    }

    /// The model's name, or the surface's when no model is named.
    var scopeName: String? {
        [scope?.model?.value, scope?.surface?.value].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }
}

/// `five_hour` / `seven_day`, the older shape.
struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

enum UsageDate {
    /// ISO 8601 with or without fractional seconds.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Rows

/// How a limit's bar is tinted. Anything but `warning` and `critical` is
/// neutral, unknown values included.
enum UsageSeverity: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical

    init(api value: String?) {
        switch value?.lowercased() {
        case "warning": self = .warning
        case "critical": self = .critical
        default: self = .normal
        }
    }

    init(from decoder: Decoder) throws {
        self.init(api: try decoder.singleValueContainer().decode(String.self))
    }
}

/// One usage row: "Weekly · Fable  ████░░  42%".
struct UsageLimit: Codable, Equatable, Sendable {
    /// The API's `kind` (`session`, `weekly_all`, `weekly_scoped`, …).
    var kind: String
    var label: String
    var percent: Double
    var severity: UsageSeverity
    var resetsAt: Date?

    static let sessionKind = "session"

    /// The row label for a limit:
    /// - `session` → "Session"
    /// - `weekly_all` / `weekly_scoped` → "Weekly"
    /// - anything else → its `group` (or `kind`) with the first letter
    ///   capitalised and underscores as spaces
    ///
    /// plus " · <name>" when the scope names a model or surface.
    static func label(kind: String?, group: String?, scopeName: String?) -> String {
        let base: String
        switch kind {
        case "session": base = "Session"
        case "weekly_all", "weekly_scoped": base = "Weekly"
        default: base = humanize(group ?? kind ?? "") ?? "Limit"
        }
        guard let scopeName, !scopeName.isEmpty else { return base }
        return "\(base) · \(scopeName)"
    }

    private static func humanize(_ text: String) -> String? {
        let words = text.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return nil }
        return first.uppercased() + words.dropFirst()
    }

    /// The rows in API order. Items without a percentage are skipped. When
    /// `limits` is missing or yields nothing, `five_hour` and `seven_day`
    /// become "Session" and "Weekly".
    static func rows(from response: UsageAPIResponse) -> [UsageLimit] {
        let rows = (response.limits ?? []).compactMap { item -> UsageLimit? in
            guard let percent = item.percent else { return nil }
            return UsageLimit(kind: item.kind ?? item.group ?? "", label: label(kind: item.kind, group: item.group, scopeName: item.scopeName),
                              percent: percent, severity: UsageSeverity(api: item.severity), resetsAt: UsageDate.parse(item.resetsAt))
        }
        if !rows.isEmpty { return rows }
        var fallback: [UsageLimit] = []
        if let window = response.fiveHour, let percent = window.utilization {
            fallback.append(UsageLimit(kind: sessionKind, label: "Session", percent: percent, severity: .normal,
                                       resetsAt: UsageDate.parse(window.resetsAt)))
        }
        if let window = response.sevenDay, let percent = window.utilization {
            fallback.append(UsageLimit(kind: "weekly_all", label: "Weekly", percent: percent, severity: .normal,
                                       resetsAt: UsageDate.parse(window.resetsAt)))
        }
        return fallback
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var limits: [UsageLimit]
    var fetchedAt: Date

    init(limits: [UsageLimit], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    init(_ response: UsageAPIResponse, fetchedAt: Date) {
        self.init(limits: UsageLimit.rows(from: response), fetchedAt: fetchedAt)
    }
}

// MARK: - Plans

/// Which limits a plan shows. The one place that decides what counts as
/// Ultra: change `ultraMarkers` when the real values are known.
enum PlanRule {
    /// Ultra (Max 20x) has no separate 5-hour limit: the API's `session`
    /// entry just mirrors the weekly one.
    static let ultraMarkers = ["ultra", "max_20x"]

    /// Whether any plan or tier string marks the account as Ultra
    /// (case-insensitive substring match).
    static func isUltra(_ values: [String?]) -> Bool {
        values.contains { value in
            guard let value = value?.lowercased() else { return false }
            return ultraMarkers.contains { value.contains($0) }
        }
    }

    static func showsSessionLimit(plan values: [String?]) -> Bool {
        !isUltra(values)
    }

    static func showsSessionLimit(for account: SavedAccount) -> Bool {
        showsSessionLimit(plan: [account.plan, account.rateLimitTier])
    }

    /// The rows to show for `account`.
    static func visibleLimits(_ limits: [UsageLimit], for account: SavedAccount) -> [UsageLimit] {
        showsSessionLimit(for: account) ? limits : limits.filter { $0.kind != UsageLimit.sessionKind }
    }
}

// MARK: - Per-account state

/// What the menu knows about one account's usage. Cached in `UserDefaults`
/// (rows, reset times, fetch time; never tokens).
struct AccountUsage: Codable, Equatable, Sendable {
    var snapshot: UsageSnapshot?
    var tokenExpired = false

    func applying(_ result: UsageResult) -> AccountUsage {
        var next = self
        switch result {
        case .fresh(let snapshot):
            next.snapshot = snapshot
            next.tokenExpired = false
        case .expired:
            next.tokenExpired = true
        case .rateLimited, .failed:
            break  // Keep the cached values.
        }
        return next
    }
}

/// How one account's usage rows look right now.
struct UsagePresentation: Equatable {
    var rows: [UsageLimit]
    /// Dim the rows: the token expired, the live login's owner is unproven,
    /// or the last fetch is old.
    var stale: Bool
    /// "as of HH:mm", shown when stale.
    var asOf: Date?
    /// Shown instead of rows when there are none.
    var placeholder: String?

    /// Older than this, cached rows count as stale (unless a fetch is running).
    static let freshFor: TimeInterval = 120

    static func make(usage: AccountUsage?, account: SavedAccount, fetching: Bool, ownerUnverified: Bool,
                     now: Date) -> UsagePresentation {
        let usage = usage ?? AccountUsage()
        guard let snapshot = usage.snapshot else {
            let placeholder: String? = if usage.tokenExpired {
                "Token expired · updates after switching"
            } else if ownerUnverified {
                "Live login unverified"
            } else if fetching {
                nil
            } else {
                "Usage unavailable"
            }
            return UsagePresentation(rows: [], stale: usage.tokenExpired || ownerUnverified, asOf: nil, placeholder: placeholder)
        }
        let old = !fetching && now.timeIntervalSince(snapshot.fetchedAt) > freshFor
        let stale = usage.tokenExpired || ownerUnverified || old
        let rows = PlanRule.visibleLimits(snapshot.limits, for: account)
        return UsagePresentation(rows: rows, stale: stale, asOf: stale ? snapshot.fetchedAt : nil,
                                 placeholder: rows.isEmpty ? "No usage limits reported" : nil)
    }

    /// "Resets in 2h 10m" within a day, otherwise the date and time.
    static func resetText(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 { return "Resets soon" }
        if seconds < 24 * 3600 {
            let minutes = Int((seconds / 60).rounded(.up))
            let hours = minutes / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes % 60)m" : "Resets in \(minutes)m"
        }
        return "Resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Cache

/// The usage cache in `UserDefaults`, key `usage.v2`. A `usage.v1` cache
/// (five-hour and seven-day percentages) is converted once and removed.
struct UsageCache: @unchecked Sendable {
    // `UserDefaults` is thread-safe; it just isn't annotated Sendable.
    let defaults: UserDefaults
    static let key = "usage.v2"
    static let legacyKey = "usage.v1"

    func load() throws -> [String: AccountUsage] {
        if let data = defaults.data(forKey: Self.key) {
            do {
                return try JSONDecoder().decode([String: AccountUsage].self, from: data)
            } catch let error as DecodingError {
                // A damaged cache: start over; the next fetch refills it.
                log.notice("Discarding usage cache: \(String(describing: error), privacy: .public)")
                defaults.removeObject(forKey: Self.key)
                return [:]
            }
        }
        guard let legacy = defaults.data(forKey: Self.legacyKey) else { return [:] }
        defaults.removeObject(forKey: Self.legacyKey)
        let migrated: [String: AccountUsage]
        do {
            migrated = try JSONDecoder().decode([String: LegacyAccountUsage].self, from: legacy).mapValues(\.current)
        } catch let error as DecodingError {
            log.notice("Discarding old usage cache: \(String(describing: error), privacy: .public)")
            return [:]
        }
        try save(migrated)
        return migrated
    }

    func save(_ usage: [String: AccountUsage]) throws {
        defaults.set(try JSONEncoder().encode(usage), forKey: Self.key)
    }

    /// The `usage.v1` format.
    private struct LegacyAccountUsage: Decodable {
        struct Snapshot: Decodable {
            var fiveHour: Double?
            var fiveHourResetsAt: Date?
            var sevenDay: Double?
            var sevenDayResetsAt: Date?
            var fetchedAt: Date
        }

        var snapshot: Snapshot?
        var tokenExpired: Bool?

        var current: AccountUsage {
            AccountUsage(snapshot: snapshot.map { old in
                var limits: [UsageLimit] = []
                if let value = old.fiveHour {
                    limits.append(UsageLimit(kind: UsageLimit.sessionKind, label: "Session", percent: value,
                                             severity: .normal, resetsAt: old.fiveHourResetsAt))
                }
                if let value = old.sevenDay {
                    limits.append(UsageLimit(kind: "weekly_all", label: "Weekly", percent: value,
                                             severity: .normal, resetsAt: old.sevenDayResetsAt))
                }
                return UsageSnapshot(limits: limits, fetchedAt: old.fetchedAt)
            }, tokenExpired: tokenExpired ?? false)
        }
    }
}
