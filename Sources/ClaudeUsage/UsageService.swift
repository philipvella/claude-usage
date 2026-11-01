import Foundation
import WebKit

struct UsageWindow {
    let key: String
    let label: String
    let utilization: Double   // 0...100
    let resetsAt: Date?
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let fetchedAt: Date

    func window(_ key: String) -> UsageWindow? { windows.first { $0.key == key } }
}

enum UsageError: LocalizedError {
    case notSignedIn
    case unauthorized
    case blocked
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .unauthorized: return "Session expired – please sign in again"
        case .blocked: return "Request blocked by claude.ai (Cloudflare) – try signing in again"
        case .http(let code): return "HTTP error \(code)"
        case .badResponse: return "Unexpected response from claude.ai"
        }
    }
}

/// Talks to the same private endpoints the claude.ai web app uses for its
/// "Usage" settings page, authenticated with the cookies captured at sign-in.
@MainActor
final class UsageService {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let base = URL(string: "https://claude.ai")!
    private static let orgDefaultsKey = "orgUUID"

    let dataStore = WKWebsiteDataStore.default()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: Cookies

    func claudeCookies() async -> [HTTPCookie] {
        let all = await dataStore.httpCookieStore.allCookies()
        return all.filter { $0.domain.hasSuffix("claude.ai") }
    }

    func isSignedIn() async -> Bool {
        await claudeCookies().contains { $0.name == "sessionKey" && !$0.value.isEmpty }
    }

    func setManualSessionKey(_ key: String) async {
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: key,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]
        if let cookie = HTTPCookie(properties: props) {
            await dataStore.httpCookieStore.setCookie(cookie)
        }
        UserDefaults.standard.removeObject(forKey: Self.orgDefaultsKey)
    }

    func signOut() async {
        UserDefaults.standard.removeObject(forKey: Self.orgDefaultsKey)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let claude = records.filter { $0.displayName.contains("claude.ai") || $0.displayName.contains("anthropic") }
        await dataStore.removeData(ofTypes: types, for: claude)
        for cookie in await claudeCookies() {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    // MARK: Fetching

    func fetch() async throws -> UsageSnapshot {
        let cookies = await claudeCookies()
        guard cookies.contains(where: { $0.name == "sessionKey" }) else { throw UsageError.notSignedIn }
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let orgId = try await resolveOrg(cookies: cookies, cookieHeader: cookieHeader)
        let data: Data
        do {
            data = try await get("/api/organizations/\(orgId)/usage", cookieHeader: cookieHeader)
        } catch UsageError.http(let code) where code == 404 || code == 403 {
            // Cached org may be stale — forget it and retry once.
            UserDefaults.standard.removeObject(forKey: Self.orgDefaultsKey)
            let fresh = try await resolveOrg(cookies: [], cookieHeader: cookieHeader)
            data = try await get("/api/organizations/\(fresh)/usage", cookieHeader: cookieHeader)
        }
        return try Self.parseUsage(data)
    }

    private func resolveOrg(cookies: [HTTPCookie], cookieHeader: String) async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: Self.orgDefaultsKey) { return cached }
        if let last = cookies.first(where: { $0.name == "lastActiveOrg" })?.value, !last.isEmpty {
            UserDefaults.standard.set(last, forKey: Self.orgDefaultsKey)
            return last
        }
        let data = try await get("/api/organizations", cookieHeader: cookieHeader)
        guard let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !orgs.isEmpty else {
            throw UsageError.badResponse
        }
        let chatOrg = orgs.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") } ?? orgs[0]
        guard let uuid = chatOrg["uuid"] as? String else { throw UsageError.badResponse }
        UserDefaults.standard.set(uuid, forKey: Self.orgDefaultsKey)
        return uuid
    }

    private func get(_ path: String, cookieHeader: String) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw UsageError.unauthorized
        case 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("Just a moment") || body.contains("cf-chl") { throw UsageError.blocked }
            if body.contains("permission_error") || body.contains("account_session_invalid") {
                throw UsageError.unauthorized
            }
            throw UsageError.http(403)
        default:
            throw UsageError.http(http.statusCode)
        }
    }

    // MARK: Parsing

    /// Tolerant parser: picks up every top-level object that has a `utilization`
    /// field (five_hour, seven_day, seven_day_opus, …) so new limits show up automatically.
    static func parseUsage(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        var windows: [UsageWindow] = []
        for (key, value) in json {
            guard let obj = value as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (obj["resets_at"] as? String).flatMap(parseDate)
            windows.append(UsageWindow(key: key, label: label(for: key), utilization: util, resetsAt: resets))
        }
        windows.sort { order(of: $0.key) < order(of: $1.key) }
        return UsageSnapshot(windows: windows, fetchedAt: Date())
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Current session (5h)"
        case "seven_day": return "Weekly – all models"
        case "seven_day_opus": return "Weekly – Opus"
        case "seven_day_sonnet": return "Weekly – Sonnet"
        case "seven_day_oauth_apps": return "Weekly – apps"
        default:
            return key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private static func order(of key: String) -> Int {
        ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].firstIndex(of: key) ?? 99
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
