import Foundation

/// Cumulative day-level category totals, aggregated from all 20-min
/// windows in today's `.cats.jsonl`. This is the PRIMARY view — the
/// whole-day picture the founder needs at 3pm.
struct DayCategorization: Equatable {
    /// Per-category totals across the entire day, sorted by ms desc.
    let categories: [CategoryBucket]
    /// Sum of all categorized time today (not clock time — just tracked active time).
    let totalActiveMs: Int64
    /// How many 20-min windows have been categorized today.
    let windowCount: Int
    /// The LLM-generated summary from the LATEST window (for "what just happened").
    let lastWindowSummary: String
    /// LLM-generated summary of the WHOLE DAY so far. Natural, fresh every
    /// 20 minutes — not a hardcoded template.
    let daySummary: String?
    /// When the most recent categorization fired.
    let lastCategorizedAt: Date

    /// What the UI shows as the day summary. Falls back to a simple
    /// time label if the LLM hasn't returned a day_summary yet
    /// (first window of the day, or server didn't include it).
    /// Numbers prefix: computed from real data, always matches the bars.
    /// e.g. "6h 19m — Learning 46%, Product 13%."
    var numbersLine: String {
        guard totalActiveMs > 0 else { return "" }
        let timeLabel = TodaySummaryView.formatDuration(totalActiveMs)
        let topCategories = categories.prefix(3)
            .map { "\($0.name) \($0.pct)%" }
            .joined(separator: ", ")
        return "\(timeLabel) — \(topCategories)."
    }

    /// Combined display: code-computed numbers + LLM qualitative text.
    /// Numbers always match the bars. Voice is always natural.
    var displayDaySummary: String {
        guard totalActiveMs > 0 else { return "No categorized time yet today." }
        if let ds = daySummary, !ds.isEmpty {
            return "\(numbersLine) \(ds)"
        }
        return "\(numbersLine)"
    }

    static let empty = DayCategorization(
        categories: [],
        totalActiveMs: 0,
        windowCount: 0,
        lastWindowSummary: "",
        daySummary: nil,
        lastCategorizedAt: .distantPast
    )
}
