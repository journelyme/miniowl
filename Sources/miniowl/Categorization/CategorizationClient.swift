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
//    - Token is read from `~/Library/Application Support/miniowl/token.txt`.
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

/// Static settings: the API URL (compile-time) and environment label.
/// Token and user context are resolved PER-REQUEST inside the client —
/// not cached — so edits to `token.txt` / `context.md` take effect on
/// the very next categorize call without any reload button.
struct CategorizationSettings {
    /// Compile-time API URL. Flipped by the `-DMINIOWL_DEV` flag in
    /// `scripts/build-app.sh --dev`. Default = production.
    static var apiURL: URL {
        #if MINIOWL_DEV
        return URL(string: "http://localhost:8000/api/v1/miniowl/categorize")!
        #else
        return URL(string: "https://api.contextly.me/api/v1/miniowl/categorize")!
        #endif
    }

    /// Human-readable environment label for diagnostics / menu display.
    static var environmentLabel: String {
        #if MINIOWL_DEV
        return "dev (localhost)"
        #else
        return "production"
        #endif
    }

    /// Resolve the current token from env var OR the token file. Called
    /// on EVERY categorize request — ~1ms file read, negligible at 20m
    /// cadence. Returns nil if no token is set (caller treats as
    /// "categorization disabled, fall back to v1 view").
    static func currentToken(dataDir: URL) -> String? {
        if let envToken = ProcessInfo.processInfo.environment["MINIOWL_TOKEN"],
           !envToken.isEmpty {
            return envToken
        }
        if let fileToken = TokenStore(dataDir: dataDir).readStripComments(),
           !fileToken.isEmpty {
            return fileToken
        }
        return nil
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
        // Resolve fresh per-request. No cache. ~1-2ms file reads.
        guard let token = CategorizationSettings.currentToken(dataDir: dataDir) else {
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
        urlRequest.setValue(token, forHTTPHeaderField: "X-Internal-Secret")
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
}
