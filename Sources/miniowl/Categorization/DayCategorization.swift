import Foundation

/// Cumulative day-level category totals, aggregated from all 20-min
/// windows in today's `.cats.jsonl`. This is the PRIMARY view — the
/// whole-day 3-circles picture the founder needs at 3pm.
struct DayCategorization: Equatable {
    /// Per-category totals across the entire day, sorted by ms desc.
    let categories: [CategoryBucket]
    /// Sum of all categorized time today (not clock time — just tracked active time).
    let totalActiveMs: Int64
    /// How many 20-min windows have been categorized today.
    let windowCount: Int
    /// The LLM-generated summary from the LATEST window (for "what just happened").
    let lastWindowSummary: String
    /// When the most recent categorization fired.
    let lastCategorizedAt: Date

    /// Template-computed day-level summary. No LLM call needed — uses
    /// the cumulative numbers to generate a founder-honest one-liner.
    ///
    /// Voice rules (same as the LLM prompt):
    ///   - Specific, not generic
    ///   - Diagnostic, not prescriptive
    ///   - Founder-tribal vocabulary
    ///   - Honest at the cost of polish
    var cumulativeSummary: String {
        guard totalActiveMs > 0 else { return "No categorized time yet today." }

        let totalHours = Double(totalActiveMs) / 3_600_000.0
        let timeLabel = TodaySummaryView.formatDuration(totalActiveMs)

        let pctByName: [String: Int] = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.name, $0.pct) }
        )

        let productPct = pctByName["Product", default: 0]
        let gtmPct = pctByName["GTM", default: 0]
        let learningPct = pctByName["Learning", default: 0]
        let personalPct = pctByName["Personal", default: 0]
        let adminPct = (pctByName["Admin", default: 0]) + (pctByName["Operations", default: 0])

        // Dispatch rules — ordered by severity. First match wins.

        // 1. Very short day — not enough signal.
        if totalHours < 0.5 {
            return "\(timeLabel) tracked — too early for a pattern."
        }

        // 2. Heavy Product + low GTM — the Joy+Skill trap (the #1 thing to detect).
        if productPct > 55 && gtmPct < 15 {
            return "\(timeLabel) active — \(productPct)% Product, \(gtmPct)% GTM. Joy+Skill pattern."
        }

        // 3. Heavy Product but GTM present — better.
        if productPct > 50 && gtmPct >= 15 {
            return "\(timeLabel) active — \(productPct)% Product, \(gtmPct)% GTM. Product-heavy but GTM present."
        }

        // 4. GTM-heavy day — rare and worth celebrating.
        if gtmPct > 35 {
            return "\(timeLabel) active — \(gtmPct)% GTM. Strong outreach day."
        }

        // 5. Too much Learning (avoidance dressed as preparation).
        if learningPct > 30 {
            return "\(timeLabel) active — \(learningPct)% Learning. Are you preparing or avoiding?"
        }

        // 6. Too much Admin/Ops overhead.
        if adminPct > 30 {
            return "\(timeLabel) active — \(adminPct)% Admin+Ops. Overhead day."
        }

        // 7. High Personal (fine on a rest day, flag on a work day).
        if personalPct > 40 {
            return "\(timeLabel) active — \(personalPct)% Personal. Rest day?"
        }

        // 8. Balanced — no single bucket dominates.
        let top = categories.first
        return "\(timeLabel) active — \(top?.name ?? "mixed") \(top?.pct ?? 0)%. Balanced day."
    }

    static let empty = DayCategorization(
        categories: [],
        totalActiveMs: 0,
        windowCount: 0,
        lastWindowSummary: "",
        lastCategorizedAt: .distantPast
    )
}
