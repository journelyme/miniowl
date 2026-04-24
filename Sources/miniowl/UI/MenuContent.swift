import AppKit
import ServiceManagement
import SwiftUI

/// The contents of the menu-bar popover. Shows a compact status header,
/// accessibility-permission prompt (if needed), today's top apps,
/// and action buttons.
struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if !state.isAccessibilityGranted {
                accessibilityBanner
                Divider()
            }

            todayBlock
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            state.recheckAccessibilityPermission()
            state.refreshSummaryNow()
            state.refreshDayCategorization()
        }
    }

    // ─── Subviews ────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.paused ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            Text("Miniowl")
                .fontWeight(.semibold)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(state.paused ? "Paused" : "Tracking")
                .foregroundStyle(.secondary)
            Spacer()
            #if MINIOWL_DEV
            Text(state.environmentLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            #endif
        }
        .font(.system(size: 13))
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission required")
                .font(.system(size: 12, weight: .semibold))
            Text("Miniowl needs to read your frontmost window title. Nothing else is read.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Open Settings") {
                    state.openAccessibilitySettings()
                }
                .controlSize(.small)
                Button("Restart Miniowl") {
                    state.restart()
                }
                .controlSize(.small)
            }
            Text("After granting, the banner clears within ~1 s. If it doesn't, click Restart Miniowl.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var todayBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Toggle between cumulative day view (default) and v1 raw apps.
            // Only show toggle if we have categorized data.
            if state.dayCategorization != nil || state.rollup != nil {
                HStack {
                    Spacer()
                    Button(state.showRawApps ? "Show categories" : "Show raw apps") {
                        state.showRawApps.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }

            if state.showRawApps {
                // v1 fallback: per-app raw totals.
                Text("Today — apps")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TodaySummaryView(summary: state.summary)
            } else if let day = state.dayCategorization {
                // PRIMARY: cumulative day view — the 3-circles picture.
                CategoryBarsView(day: day)
            } else {
                // No categorizations yet — show v1 + status.
                Text("Today — apps")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TodaySummaryView(summary: state.summary)
                if let err = state.rollupError {
                    Text("Categorization: \(err)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else if state.hasToken {
                    Text("Waiting for first categorization (every 20 min)…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(state.paused ? "Resume tracking" : "Pause tracking") {
                state.togglePause()
            }
            .keyboardShortcut("p")
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Open data folder") {
                state.openDataFolder()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            // v2.0 — manual refresh of categories (skips the 20-min wait).
            // Only meaningful if a token is configured.
            if state.hasToken {
                Button("Categorize now") {
                    state.categorizeNow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // v2.0 — token + context. Both files are read fresh from
            // disk on every categorize call; no reload button needed.
            Button(state.hasToken ? "Edit token…" : "Set token…") {
                state.editToken()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Edit context…") {
                state.editContext()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            if state.loginItemStatus != .enabled {
                Button("Login items settings…") {
                    state.openLoginItemSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .padding(.vertical, 2)

            Button("Quit Miniowl") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
