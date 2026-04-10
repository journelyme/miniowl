import Foundation

/// A simple aggregation of today's data for the menu-bar "Today" view.
struct DailySummary: Equatable {
    var topApps: [DailyTotal]
    var afkMs: Int64

    static let empty = DailySummary(topApps: [], afkMs: 0)

    /// Total active (non-AFK) time across all apps.
    var totalActiveMs: Int64 {
        topApps.reduce(0) { $0 + $1.activeMs }
    }
}

struct DailyTotal: Equatable, Identifiable {
    let bundleID: String
    let appName: String
    let activeMs: Int64

    var id: String { bundleID }
}

/// Reads a `.mow` JSONL file and reduces it to a per-app totals view.
///
/// Single pass, synchronous, ~no allocations beyond the parsed JSON
/// dictionaries. A day's file is ~70 KB / ~500 lines, which takes
/// under 10 ms to parse on an M-series Mac — cheap enough to run from
/// the menu bar refresh path directly.
enum LogReader {
    /// Read + summarize a single `.mow` file. Missing or malformed files
    /// return `DailySummary.empty`.
    static func summarize(file: URL) -> DailySummary {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return .empty
        }

        var appTotals: [String: (name: String, ms: Int64)] = [:]
        var afkMs: Int64 = 0

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? String
            else { continue }

            switch t {
            case "w":
                guard let s = (obj["s"] as? NSNumber)?.int64Value,
                      let e = (obj["e"] as? NSNumber)?.int64Value,
                      let b = obj["b"] as? String,
                      let n = obj["n"] as? String
                else { continue }
                let dur = e - s
                guard dur >= 0 else { continue }
                let existing = appTotals[b] ?? (name: n, ms: 0)
                appTotals[b] = (name: n, ms: existing.ms + dur)

            case "a":
                guard let s = (obj["s"] as? NSNumber)?.int64Value,
                      let e = (obj["e"] as? NSNumber)?.int64Value
                else { continue }
                let dur = e - s
                if dur > 0 { afkMs += dur }

            default:
                break
            }
        }

        let sorted: [DailyTotal] = appTotals
            .map { DailyTotal(bundleID: $0.key, appName: $0.value.name, activeMs: $0.value.ms) }
            .sorted { $0.activeMs > $1.activeMs }

        return DailySummary(topApps: sorted, afkMs: afkMs)
    }
}
