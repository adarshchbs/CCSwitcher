import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Usage")

/// An access token to read usage with. Never refreshed here: Claude Code
/// refreshes its own tokens.
struct UsageToken: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
}

protocol HTTPGetting: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// The app's only network access. Ephemeral: no cookies, no cache on disk.
struct URLSessionHTTP: HTTPGetting {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum UsageResult: Equatable, Sendable {
    case fresh(UsageSnapshot)
    /// The token expired. No request was sent, or the server answered 401.
    case expired
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

/// Reads `GET https://api.anthropic.com/api/oauth/usage`.
struct UsageClient: Sendable {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let http: HTTPGetting
    let clock: Clock

    init(http: HTTPGetting = URLSessionHTTP(), clock: Clock) {
        self.http = http
        self.clock = clock
    }

    func fetch(_ token: UsageToken) async throws -> UsageResult {
        if let expiresAt = token.expiresAt, expiresAt <= clock.now() { return .expired }

        var request = URLRequest(url: Self.url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.get(request)
        } catch let error as URLError {
            log.notice("Usage request failed: \(error.code.rawValue, privacy: .public)")
            return .failed("network error \(error.code.rawValue)")
        }

        switch response.statusCode {
        case 200:
            do {
                let body = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
                return .fresh(UsageSnapshot(body, fetchedAt: clock.now()))
            } catch let error as DecodingError {
                log.error("Usage response didn't decode: \(String(describing: error), privacy: .public)")
                return .failed("unexpected response")
            }
        case 401:
            return .expired
        case 429:
            return .rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default:
            log.notice("Usage request answered \(response.statusCode, privacy: .public)")
            return .failed("HTTP \(response.statusCode)")
        }
    }
}

/// The parts of the usage response the app shows (from upstream's model).
struct UsageAPIResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var fiveHour: Double?
    var fiveHourResetsAt: Date?
    var sevenDay: Double?
    var sevenDayResetsAt: Date?
    var fetchedAt: Date

    init(fiveHour: Double?, fiveHourResetsAt: Date?, sevenDay: Double?, sevenDayResetsAt: Date?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDay = sevenDay
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
    }

    init(_ response: UsageAPIResponse, fetchedAt: Date) {
        self.init(fiveHour: response.fiveHour?.utilization, fiveHourResetsAt: response.fiveHour?.resetsAtDate,
                  sevenDay: response.sevenDay?.utilization, sevenDayResetsAt: response.sevenDay?.resetsAtDate,
                  fetchedAt: fetchedAt)
    }
}

/// What the menu knows about one account's usage. Cached in `UserDefaults`
/// (percentages, reset times, fetch time; never tokens).
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

    /// `5h 42% · 7d 63%`, with the fetch time when it isn't current.
    func summary(now: Date) -> String {
        guard let snapshot else {
            return tokenExpired ? "token expired · refreshes after switching" : "usage unavailable"
        }
        var text = "5h \(Self.percent(snapshot.fiveHour)) · 7d \(Self.percent(snapshot.sevenDay))"
        if tokenExpired || now.timeIntervalSince(snapshot.fetchedAt) > 120 {
            let time = snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
            text += tokenExpired ? "  (as of \(time) · refreshes after switching)" : "  (as of \(time))"
        }
        return text
    }

    private static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "–"
    }
}

/// The usage cache in `UserDefaults`, key `usage.v1`.
struct UsageCache: @unchecked Sendable {
    // `UserDefaults` is thread-safe; it just isn't annotated Sendable.
    let defaults: UserDefaults
    let key = "usage.v1"

    func load() throws -> [String: AccountUsage] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: AccountUsage].self, from: data)
        } catch let error as DecodingError {
            // An older or damaged cache: start over; the next fetch refills it.
            log.notice("Discarding usage cache: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    func save(_ usage: [String: AccountUsage]) throws {
        defaults.set(try JSONEncoder().encode(usage), forKey: key)
    }
}
