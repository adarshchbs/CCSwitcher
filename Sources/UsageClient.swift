import Foundation
import os

private let log = Logger(subsystem: "com.adarshchbs.ccswitcher", category: "Usage")

/// An access token to read usage with. Never refreshed here: Claude Code
/// refreshes its own tokens.
struct UsageToken: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?

    func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
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

/// The app's only network access, shared by the usage and profile requests.
/// Ephemeral, with no cookies, no URL cache and no credential storage, and
/// it refuses every redirect: a request carrying a bearer token goes to the
/// URL the app built or nowhere.
///
/// `@unchecked Sendable`: `session` is immutable and `URLSession` is
/// thread-safe.
final class EphemeralHTTP: HTTPGetting, @unchecked Sendable {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Answers every redirect with "don't follow". The 3xx response then comes
/// back to the caller, which treats it as a failure.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        log.notice("Refused a redirect (HTTP \(response.statusCode, privacy: .public))")
        completionHandler(nil)
    }
}

/// The organization an access token belongs to.
enum OrgLookupResult: Equatable, Sendable {
    /// `rateLimitTier` is `organization.rate_limit_tier`, kept to tell plans
    /// apart (see `PlanRule`).
    case organization(uuid: String, name: String?, rateLimitTier: String? = nil)
    /// 401 or 403: the token is expired or revoked.
    case unauthorized
    case failed(String)
}

protocol OrgLookup: Sendable {
    func organization(accessToken: String) async throws -> OrgLookupResult
}

/// Reads `GET https://api.anthropic.com/api/oauth/profile`, the way Claude
/// Code does, to learn which organization an access token belongs to. Sends
/// the access token only; the refresh token never leaves the Keychain.
struct ProfileClient: OrgLookup {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    let http: HTTPGetting

    func organization(accessToken: String) async throws -> OrgLookupResult {
        var request = URLRequest(url: Self.url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.get(request)
        } catch let error as URLError {
            log.notice("Profile request failed: \(error.code.rawValue, privacy: .public)")
            return .failed("network error \(error.code.rawValue)")
        }

        switch response.statusCode {
        case 200:
            do {
                let body = try JSONDecoder().decode(ProfileAPIResponse.self, from: data)
                guard let uuid = body.organization?.uuid, !uuid.isEmpty else { return .failed("no organization in the response") }
                return .organization(uuid: uuid, name: body.organization?.name,
                                     rateLimitTier: body.organization?.rateLimitTier)
            } catch let error as DecodingError {
                log.error("Profile response didn't decode: \(String(describing: error), privacy: .public)")
                return .failed("unexpected response")
            }
        case 401, 403:
            return .unauthorized
        default:
            log.notice("Profile request answered \(response.statusCode, privacy: .public)")
            return .failed("HTTP \(response.statusCode)")
        }
    }
}

/// The parts of the profile response the app reads.
struct ProfileAPIResponse: Decodable {
    struct Organization: Decodable {
        let uuid: String?
        let name: String?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case uuid, name
            case rateLimitTier = "rate_limit_tier"
        }
    }

    let organization: Organization?
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

    init(http: HTTPGetting, clock: Clock) {
        self.http = http
        self.clock = clock
    }

    func fetch(_ token: UsageToken) async throws -> UsageResult {
        if token.isExpired(at: clock.now()) { return .expired }

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
