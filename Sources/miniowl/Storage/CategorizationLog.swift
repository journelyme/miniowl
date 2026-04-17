import Foundation

/// Persisted log of categorization results.
///
/// Mirrors the `.mow` JSONL convention: one file per local date, one line
/// per rollup. Filename: `YYYY-MM-DD.cats.jsonl` (distinct extension so
/// it coexists with the event log in the same directory).
///
/// Why persist:
///   - Menu bar popover needs to show the last rollup immediately on
///     app restart. Without this, the user sees "waiting for first
///     categorization…" every time they relaunch.
///   - Future analytics ("show me my Sweet Spot % over the last 7 days")
///     just needs to glob `*.cats.jsonl` and grep.
///
/// Not gzipped: each line is ~500 B, max ~72 lines/day (every 20 min
/// during a 24 h day), so daily files cap at ~35 KB. Cumulative: a year
/// of data is ~13 MB. No rotation/compression needed for now.
struct CategorizationLog {
    let dataDir: URL

    // MARK: - On-disk format

    /// One JSONL row. The shape mirrors the server response + the
    /// request metadata, so a future reader can rebuild the full context
    /// (window range, timezone) without a second lookup.
    struct Entry: Codable {
        /// Event-type letter — matches the `.mow` convention ('w','a','s').
        /// 'c' = categorization.
        let t: String
        /// Unix ms UTC — when this rollup was computed on the client.
        let at: Int64
        /// The window the rollup covered (from the request).
        let window_start: Int64
        let window_end: Int64
        let tz: String
        /// Server-returned categories + summary.
        let categories: [CategoryBucket]
        let summary: String

        init(cached: CachedRollup, request: CategorizationRequest) {
            self.t = "c"
            self.at = Int64(cached.computedAt.timeIntervalSince1970 * 1000)
            self.window_start = request.window_start
            self.window_end = request.window_end
            self.tz = request.tz
            self.categories = cached.response.categories
            self.summary = cached.response.summary
        }
    }

    // MARK: - Paths

    func fileURL(for date: Date) -> URL {
        dataDir.appendingPathComponent("\(DateUtils.localDateString(for: date)).cats.jsonl")
    }

    // MARK: - Write

    /// Append one line to today's file. Creates the file if needed.
    /// Atomic: we use FileHandle.write with O_APPEND semantics (single
    /// writer — called only from the coordinator task on the main queue
    /// that processes categorize completions, so no races).
    func append(_ cached: CachedRollup, request: CategorizationRequest) throws {
        let entry = Entry(cached: cached, request: request)
        let data = try JSONEncoder().encode(entry)

        let url = fileURL(for: Date())
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            // Ensure directory exists (should already — dataDir is
            // created at app start).
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Create an empty file so FileHandle(forWritingTo:) works.
            fm.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))  // newline
    }

    // MARK: - Read

    /// Read the most recent rollup from today's file, OR the most recent
    /// file if today's doesn't exist yet (e.g. after midnight before the
    /// first categorize of the new day).
    ///
    /// Called once on app start to prime the menu.
    func readLatest() -> CachedRollup? {
        // Prefer today's file.
        if let latest = readLastEntry(from: fileURL(for: Date())) {
            return toCachedRollup(latest)
        }

        // Fall back to the most recent .cats.jsonl file in the dir.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let catsFiles = entries
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasSuffix(".cats.jsonl") }
            .sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return ad > bd
            }

        for url in catsFiles {
            if let latest = readLastEntry(from: url) {
                return toCachedRollup(latest)
            }
        }
        return nil
    }

    // MARK: - Day aggregation

    /// Read ALL entries from today's `.cats.jsonl` and aggregate into a
    /// cumulative day view. This is the primary menu bar display — "where
    /// am I spending my day?" vs the 20-min window's "what just happened?"
    ///
    /// Cost: ~35 KB file scan, ~1 ms. Called on each new rollup + on
    /// startup. Safe from the main thread.
    func readToday() -> DayCategorization? {
        let url = fileURL(for: Date())
        guard let data = try? Data(contentsOf: url) else { return nil }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.isEmpty { return nil }

        var totals: [String: Int64] = [:]
        var lastSummary = ""
        var lastAt: Int64 = 0
        var count = 0

        for line in lines {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)) else {
                continue
            }
            for cat in entry.categories {
                totals[cat.name, default: 0] += Int64(cat.ms)
            }
            lastSummary = entry.summary
            if entry.at > lastAt { lastAt = entry.at }
            count += 1
        }

        if totals.isEmpty { return nil }

        let totalMs = totals.values.reduce(0 as Int64, +)
        let categories = totals.map { name, ms in
            CategoryBucket(
                name: name,
                ms: ms,
                pct: totalMs > 0 ? Int(Double(ms) / Double(totalMs) * 100) : 0
            )
        }.sorted { $0.ms > $1.ms }

        return DayCategorization(
            categories: categories,
            totalActiveMs: totalMs,
            windowCount: count,
            lastWindowSummary: lastSummary,
            lastCategorizedAt: Date(timeIntervalSince1970: Double(lastAt) / 1000)
        )
    }

    // MARK: - Helpers

    /// Read the last non-empty line and decode it as an Entry.
    /// Streams from the end of the file so we never allocate the whole
    /// file for large days. Tolerant of partial/malformed last lines.
    private func readLastEntry(from url: URL) -> Entry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Walk backwards to find the last newline-delimited line.
        // Reading ~35 KB max is cheap — no need for stream seek gymnastics.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let lastLine = lines.last else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: Data(lastLine))
    }

    private func toCachedRollup(_ entry: Entry) -> CachedRollup {
        let response = CategorizationResponse(
            categories: entry.categories,
            summary: entry.summary
        )
        let date = Date(timeIntervalSince1970: Double(entry.at) / 1000.0)
        return CachedRollup(response: response, computedAt: date)
    }
}
