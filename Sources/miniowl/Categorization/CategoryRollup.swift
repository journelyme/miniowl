import Foundation

/// Build a categorization request from on-disk events.
///
/// Why read from disk vs. a coordinator-side ring buffer: simpler and
/// more honest. The coordinator already flushes closed events to JSONL;
/// reading them back means the categorizer reasons about exactly the
/// data persisted, with zero risk of drift. Cost: ~10ms to scan a 70KB
/// daily file (LogReader benchmark) — negligible against a 20-min cadence.
enum CategoryRollup {
    /// Default look-back window for the periodic timer.
    static let defaultWindow: TimeInterval = 20 * 60  // 20 minutes

    /// Trim window titles + URLs to keep payloads small AND defensive
    /// against accidental long-string leakage. The LLM only needs the
    /// "topic" part of a title, not the entire IDE breadcrumb.
    static let maxTitleChars = 120
    static let maxURLChars = 120

    /// Cap the number of events sent per call. The Python service caps
    /// at 500; we cap on the client side too so a malformed log can't
    /// blow up the payload.
    static let maxEvents = 400

    /// Build the request body covering the last `window` seconds of
    /// events from `file`. Returns nil if the file is missing or the
    /// window is empty (caller should skip the API call entirely).
    static func buildRequest(
        file: URL,
        window: TimeInterval = defaultWindow,
        now: Date = Date(),
        timezone: TimeZone = .current
    ) -> CategorizationRequest? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let windowStartMs = Int64((now.timeIntervalSince1970 - window) * 1000)

        // Aggregate identical (b, ti, u) triples that fall in the window
        // so the LLM doesn't see the same row 30 times.
        struct Key: Hashable {
            let b: String
            let ti: String?
            let u: String?
            let n: String?
        }
        var bucket: [Key: Int64] = [:]

        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let data = raw.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (obj["t"] as? String) == "w",
                let s = (obj["s"] as? NSNumber)?.int64Value,
                let e = (obj["e"] as? NSNumber)?.int64Value,
                let b = obj["b"] as? String
            else { continue }

            // Window overlap: keep events that touch [windowStart, now].
            let overlapStart = max(s, windowStartMs)
            let overlapEnd = min(e, nowMs)
            let dur = overlapEnd - overlapStart
            guard dur > 0 else { continue }

            let n = obj["n"] as? String
            let ti = (obj["ti"] as? String).map { Self.truncate($0, max: maxTitleChars) }
            let u = (obj["u"] as? String).flatMap(Self.normalizeURL)

            let key = Key(b: b, ti: ti, u: u, n: n)
            bucket[key, default: 0] += dur
        }

        if bucket.isEmpty { return nil }

        // Sort by ms desc, take top N.
        let sorted = bucket
            .map { (key, ms) in (key, ms) }
            .sorted { $0.1 > $1.1 }
            .prefix(maxEvents)

        let events = sorted.map { (key, ms) -> CategorizationEvent in
            CategorizationEvent(b: key.b, n: key.n, ti: key.ti, u: key.u, ms: ms)
        }

        return CategorizationRequest(
            tz: timezone.identifier,
            window_start: windowStartMs,
            window_end: nowMs,
            events: events
        )
    }

    // MARK: - Privacy hygiene helpers

    /// Window titles can be long. Trim aggressively — categorization only
    /// needs the topic word (e.g. "GTM strategy" or "main.go"), not the
    /// full breadcrumb path that some IDEs include.
    static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }

    /// Reduce a URL to host + first path segment. We don't need full URLs
    /// (which can contain query params, tokens, doc ids) to know the
    /// category. "docs.google.com/document" tells us the same thing as
    /// the full link, with much less leakage risk.
    static func normalizeURL(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw), let host = comps.host else {
            return nil
        }
        let firstPath = comps.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        let combined = firstPath.map { "\(host)/\($0)" } ?? host
        return truncate(combined, max: maxURLChars)
    }
}
