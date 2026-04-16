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

/// Settings for the categorization client.
///
/// URL is compile-time: `#if MINIOWL_DEV` → localhost, else production.
/// Token is runtime: read from `token.txt` in the data dir, or the
/// `MINIOWL_TOKEN` env var (for CI / swift run).
struct CategorizationSettings {
    let endpoint: URL
    let token: String

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

    /// Resolve settings. Returns nil if no token is available — caller
    /// treats that as "v2.0 disabled, show v1 raw view".
    ///
    /// Token resolution order:
    ///   1. `MINIOWL_TOKEN` env var (for `swift run` / CI)
    ///   2. `~/Library/Application Support/miniowl/token.txt` (production path)
    static func resolve(dataDir: URL) -> CategorizationSettings? {
        if let envToken = ProcessInfo.processInfo.environment["MINIOWL_TOKEN"],
           !envToken.isEmpty {
            return CategorizationSettings(endpoint: apiURL, token: envToken)
        }
        if let fileToken = TokenStore(dataDir: dataDir).readStripComments(),
           !fileToken.isEmpty {
            return CategorizationSettings(endpoint: apiURL, token: fileToken)
        }
        return nil
    }
}

/// HTTPS POST to the categorization gateway. Stateless, request-scoped
/// — one URLSession per call is fine for our request rate (~3/hour).
struct CategorizationClient {
    let settings: CategorizationSettings

    /// Default 30-second timeout matches the Go backend client and gives
    /// generous headroom for Claude Haiku at p99 (~3 s typical).
    var timeout: TimeInterval = 30

    func categorize(_ request: CategorizationRequest) async throws -> CategorizationResponse {
        var urlRequest = URLRequest(
            url: settings.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(settings.token, forHTTPHeaderField: "X-Internal-Secret")
        urlRequest.setValue("miniowl/2.0", forHTTPHeaderField: "User-Agent")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
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
