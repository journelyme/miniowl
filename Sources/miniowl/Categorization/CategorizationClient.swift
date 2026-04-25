// ─────────────────────────────────────────────────────────────────────
//  CategorizationClient.swift
//
//  THE ONE FILE in miniowl that talks to the network.
//
//  Privacy contract for v2.0:
//    - This file is the ONLY place URLSession may appear. Enforced by
//      `scripts/check-privacy.sh` (allowlist).
//    - Payload contains only: bundle id, app name, window title, URL host,
//      duration. No clipboard, no keystrokes, no screen pixels, no body
//      content. See `Categorization/Models.swift` for the exact wire shape.
//    - URL is baked at BUILD time (dev vs prod via `#if MINIOWL_DEV`).
//      No runtime env var, no way for a shipped binary to be redirected.
//    - Device token is read from macOS Keychain (RFC 8628 pairing flow).
//      Empty / missing → categorization silently disabled, v1 fallback.
//    - If the client is misconfigured, the menu bar falls back to v1 view.
// ─────────────────────────────────────────────────────────────────────

import Foundation

enum CategorizationError: Error, LocalizedError {
    case notConfigured
    case httpError(status: Int)
    case decode(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "categorization not configured"
        case .httpError(let s): return "HTTP \(s)"
        case .decode(let e): return "decode error: \(e)"
        case .transport(let e): return "transport error: \(e)"
        }
    }
}

/// Static settings: the API URLs (compile-time) and environment label.
/// Device token and user context are resolved PER-REQUEST inside the client —
/// not cached — so edits to `context.md` take effect on the very next
/// categorize call without any reload button.
struct CategorizationSettings {
    /// Base API URL. Flipped by the `-DMINIOWL_DEV` flag in
    /// `scripts/build-app.sh --dev`. Default = production.
    static var baseURL: URL {
        #if MINIOWL_DEV
        return URL(string: "http://localhost:8000/api/v1/miniowl")!
        #else
        return URL(string: "https://api.contextly.me/api/v1/miniowl")!
        #endif
    }

    /// Categorization endpoint URL
    static var apiURL: URL {
        baseURL.appendingPathComponent("categorize")
    }

    /// Pairing start endpoint URL
    static var pairStartURL: URL {
        baseURL.appendingPathComponent("pair/start")
    }

    /// Pairing poll endpoint URL
    static var pairPollURL: URL {
        baseURL.appendingPathComponent("pair/poll")
    }

    /// Human-readable environment label for diagnostics / menu display.
    static var environmentLabel: String {
        #if MINIOWL_DEV
        return "dev (localhost)"
        #else
        return "production"
        #endif
    }

    /// Resolve the current device token from macOS Keychain. Called on
    /// EVERY categorize request. Returns nil if the user hasn't paired yet
    /// — the caller treats that as "categorization disabled, fall back to
    /// v1 view" and the menu shows "Connect account…".
    static func currentToken() -> String? {
        let store = DeviceTokenStore()
        guard let token = store.read(), !token.isEmpty else { return nil }
        return token
    }

    /// Resolve the current user context from the context file. Called on
    /// EVERY categorize request. Returns nil if file missing / empty /
    /// placeholder-only — server falls back to defaults.
    static func currentUserContext(dataDir: URL) -> String? {
        return ContextStore(dataDir: dataDir).read()
    }
}

/// HTTPS POST to the categorization gateway. Stateless, request-scoped
/// — one URLSession per call is fine for our request rate (~3/hour).
/// Token + user context are resolved fresh from disk on every call.
struct CategorizationClient {
    let dataDir: URL

    /// Default 30-second timeout matches the Go backend client and gives
    /// generous headroom for Claude Haiku at p99 (~3 s typical).
    var timeout: TimeInterval = 30

    func categorize(_ request: CategorizationRequest) async throws -> CategorizationResponse {
        // Resolve fresh per-request. No cache. ~1ms Keychain read.
        guard let token = CategorizationSettings.currentToken() else {
            throw CategorizationError.notConfigured
        }
        let userContext = CategorizationSettings.currentUserContext(dataDir: dataDir)

        // Rolling 7-day totals from on-disk .cats.jsonl files. ~7ms.
        // Lets the LLM spot multi-day patterns (e.g. "5th Product-heavy day").
        let weekBuckets = CategorizationLog(dataDir: dataDir).readLastNDays(7)
        let weekTotals: [DayTotalPayload]? = weekBuckets.isEmpty
            ? nil
            : weekBuckets.map { DayTotalPayload(name: $0.name, ms: $0.ms, pct: $0.pct) }

        // Inject week totals + user context into the request body.
        let bodyWithContext = CategorizationRequest(
            tz: request.tz,
            window_start: request.window_start,
            window_end: request.window_end,
            events: request.events,
            day_totals: request.day_totals,
            day_active_ms: request.day_active_ms,
            week_totals: weekTotals,
            user_context: userContext
        )

        var urlRequest = URLRequest(
            url: CategorizationSettings.apiURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Miniowl/2.0", forHTTPHeaderField: "User-Agent")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(bodyWithContext)
        } catch {
            throw CategorizationError.decode(error)
        }

        // URLSession.shared is fine — the ephemeral configuration would
        // also work, but shared is the standard cross-request pool and
        // we benefit from connection reuse if the user has multiple
        // back-to-back categorizations queued (rare).
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw CategorizationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CategorizationError.httpError(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CategorizationError.httpError(status: http.statusCode)
        }

        do {
            return try CategorizationResponse.decode(data)
        } catch {
            throw CategorizationError.decode(error)
        }
    }

    // MARK: - Pairing Endpoints

    /// Start the device pairing flow (POST /api/v1/miniowl/pair/start)
    static func pairStart(_ request: PairStartRequest) async throws -> PairStartResponse {
        var urlRequest = URLRequest(
            url: CategorizationSettings.pairStartURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Miniowl/2.0", forHTTPHeaderField: "User-Agent")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw CategorizationError.decode(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw CategorizationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CategorizationError.httpError(status: -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CategorizationError.httpError(status: http.statusCode)
        }

        do {
            return try PairStartResponse.decode(data)
        } catch {
            throw CategorizationError.decode(error)
        }
    }

    /// Poll for pairing approval (GET /api/v1/miniowl/pair/poll)
    static func pairPoll(deviceCode: String) async throws -> PairPollResponse {
        var components = URLComponents(url: CategorizationSettings.pairPollURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "device_code", value: deviceCode)]

        guard let url = components.url else {
            throw CategorizationError.transport(NSError(domain: "URLError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Miniowl/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw CategorizationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CategorizationError.httpError(status: -1)
        }

        // Handle specific HTTP status codes for pairing
        if http.statusCode == 410 {
            return PairPollResponse(status: "expired", device_token: nil)
        } else if http.statusCode == 403 {
            return PairPollResponse(status: "denied", device_token: nil)
        } else if http.statusCode == 404 {
            return PairPollResponse(status: "expired", device_token: nil)
        } else if !(200..<300).contains(http.statusCode) {
            throw CategorizationError.httpError(status: http.statusCode)
        }

        do {
            return try PairPollResponse.decode(data)
        } catch {
            throw CategorizationError.decode(error)
        }
    }
}
