import SwiftUI

/// v2.0 — Cumulative day-level category view for the menu bar.
///
/// PRIMARY view: shows the entire day's allocation ("where is my day
/// going?") — the real 3-circles honesty meter.
///
/// Secondary: the last-window LLM summary is shown as a compact one-liner
/// below the cumulative bars ("what just happened?").
struct CategoryBarsView: View {
    let day: DayCategorization

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Day header: total time + window count
            HStack {
                Text("Today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(TodaySummaryView.formatDuration(day.totalActiveMs)) active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(day.windowCount) windows")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Cumulative category bars — the whole-day picture.
            ForEach(day.categories) { bucket in
                CategoryBarRow(
                    bucket: bucket,
                    color: color(for: bucket.name)
                )
            }

            // Cumulative summary — template-computed, no LLM.
            // This is the 3-circles diagnostic ("62% Product, 15% GTM —
            // Joy+Skill pattern.").
            if day.totalActiveMs > 0 {
                Text("ⓘ  \(day.cumulativeSummary)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            // Last-window LLM summary — what the model said about the
            // most recent 20-min chunk. Secondary signal.
            if !day.lastWindowSummary.isEmpty {
                Text("Last window: \(day.lastWindowSummary)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            // Footer: when last categorized.
            HStack {
                Spacer()
                Text("Categorized \(Self.timeAgo(day.lastCategorizedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for name: String) -> Color {
        switch CircleColor.forCategory(name) {
        case .sweetSpot: return .green
        case .joySkill:  return .yellow
        case .skillNeed: return .orange
        case .needOnly:  return .red
        case .personal:  return .blue
        case .neutral:   return .gray
        }
    }

    static func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(max(secs, 1))s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        return "\(hrs)h ago"
    }
}

/// One progress bar + label + duration.
struct CategoryBarRow: View {
    let bucket: CategoryBucket
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(bucket.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(bucket.pct)%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(TodaySummaryView.formatDuration(bucket.ms))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.85))
                        .frame(
                            width: max(2, geo.size.width * CGFloat(bucket.pct) / 100)
                        )
                }
            }
            .frame(height: 6)
        }
    }
}
