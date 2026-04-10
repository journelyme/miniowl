import SwiftUI

/// Compact "Today" block rendered inside the menu bar popover.
struct TodaySummaryView: View {
    let summary: DailySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.topApps.isEmpty {
                Text("No data yet — switch an app to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.topApps.prefix(6)) { app in
                    HStack {
                        Text(app.appName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(Self.formatDuration(app.activeMs))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
                if summary.afkMs > 0 {
                    HStack {
                        Text("— AFK")
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(Self.formatDuration(summary.afkMs))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                }
            }
        }
    }

    /// "2h 14m" / "45m" / "3s" depending on magnitude.
    static func formatDuration(_ ms: Int64) -> String {
        let totalSec = max(0, ms) / 1000
        let hours = totalSec / 3600
        let mins = (totalSec % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins > 0 { return "\(mins)m" }
        return "\(totalSec)s"
    }
}
