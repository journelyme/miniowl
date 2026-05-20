import Foundation

/// Wire-format models for the categorization API.
///
/// These mirror the server contract exactly. Field names are
/// intentionally short (`b`, `ti`, `u`, `ms`) to keep the payload
/// compact — same convention as miniowl's on-disk JSONL format.

// MARK: - Request

/// One observed window/AFK interval, the unit the categorizer reasons over.
///
/// We send only what the LLM actually needs to disambiguate intent:
///   - `b` (bundle id)
///   - `n` (display name — helps the prompt sound natural)
///   - `ti` (window title — the strongest intent signal)
///   - `u` (URL — only set for whitelisted browsers; the second strongest)
///   - `ms` (duration)
///
/// We do NOT send: clipboard contents, page content, keystrokes, screenshots.
/// See README "Privacy contract".
struct CategorizationEvent: Codable, Equatable {
    let b: String              // bundle id
    let n: String?             // app display name
    let ti: String?            // window title (truncated)
    let u: String?             // active tab URL (truncated, host+path only)
    let ms: Int64              // duration ms
}

struct DayTotalPayload: Codable {
    let name: String
    let ms: Int64
    let pct: Int
}

struct CategorizationRequest: Codable {
    let tz: String
    let window_start: Int64    // Unix ms UTC
    let window_end: Int64      // Unix ms UTC
    let events: [CategorizationEvent]
    let day_totals: [DayTotalPayload]?
    let day_active_ms: Int64?
    /// Rolling 7-day aggregate (today + 6 prior days). Used by LLM to
    /// spot multi-day patterns — e.g. "5th consecutive Product-heavy day".
    let week_totals: [DayTotalPayload]?
    /// Free-form user context from ~/Library/Application Support/miniowl/context.md.
    /// Optional. Server appends to system prompt as additional user guidance.
    /// Capped at 8 KB client-side.
    let user_context: String?
}

// MARK: - Response

struct CategoryBucket: Codable, Equatable, Identifiable {
    let name: String
    let ms: Int64
    let pct: Int

    var id: String { name }
}

/// Server returns either a success envelope from the Go backend
/// (`{success, data, error}`) OR the raw Python shape (gateway pass-through).
/// We accept both so changes to envelope policy don't break the client.
struct CategorizationResponse: Codable, Equatable {
    let categories: [CategoryBucket]
    let summary: String
    let day_summary: String?

    /// Decode tolerantly: try the wrapped Go envelope first, then the raw
    /// Python shape, then surface a useful error.
    static func decode(_ data: Data) throws -> CategorizationResponse {
        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(GoEnvelope.self, from: data),
           let inner = wrapped.data {
            return inner
        }
        return try decoder.decode(CategorizationResponse.self, from: data)
    }

    private struct GoEnvelope: Codable {
        let success: Bool
        let data: CategorizationResponse?
        let error: String?
    }
}

// MARK: - Cached rollup (persisted between API calls)

/// What we render in the menu bar between API calls. Stored in memory
/// only — no extra disk file. (state.json is reserved for crash recovery
/// of the EventCoordinator's pending event.)
struct CachedRollup: Equatable {
    let response: CategorizationResponse
    let computedAt: Date
}
