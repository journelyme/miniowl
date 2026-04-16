import SwiftUI

/// v2.0 — Category roll-up view for the menu bar.
///
/// Renders bars per category, with color = 3-circles failure-mode palette,
/// and the LLM-generated one-line summary below. Designed to be readable
/// in <1 second — bars + percentages, nothing else above the fold.
struct CategoryBarsView: View {
    let cached: CachedRollup
    let totalActiveMs: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Bars — sorted server-side by ms desc.
            ForEach(cached.response.categories) { bucket in
                CategoryBarRow(
                    bucket: bucket,
                    color: color(for: bucket.name)
                )
            }

            // Founder-honest summary line. The whole product is about
            // putting friction at the moment of choice; this is that line.
            if !cached.response.summary.isEmpty {
                Text("ⓘ  \(cached.response.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            // Footer: when categorized.
            HStack {
                Spacer()
                Text("Categorized \(Self.timeAgo(cached.computedAt))")
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

    /// "12s ago", "4m ago", "1h ago" — keep it terse.
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
