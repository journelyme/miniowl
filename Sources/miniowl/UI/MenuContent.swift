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
            // The polling timer might be paused or have a stale cache;
            // re-check directly so the user's first click after granting
            // permission flips the banner immediately.
            state.recheckAccessibilityPermission()
            state.refreshSummaryNow()
        }
    }

    // ─── Subviews ────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.paused ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            Text("miniowl")
                .fontWeight(.semibold)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(state.paused ? "Paused" : "Tracking")
                .foregroundStyle(.secondary)
            Spacer()
            // Build-env label — always visible so the user knows
            // whether their data is going to localhost or production.
            Text(state.environmentLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission required")
                .font(.system(size: 12, weight: .semibold))
            Text("miniowl needs to read your frontmost window title. Nothing else is read.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Open Settings") {
                    state.openAccessibilitySettings()
                }
                .controlSize(.small)
                Button("Restart miniowl") {
                    state.restart()
                }
                .controlSize(.small)
            }
            Text("After granting, the banner clears within ~1 s. If it doesn't, click Restart.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var todayBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.showRawApps || state.rollup == nil ? "Today — apps" : "Today — categories")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // Toggle only meaningful once we have categorized data.
                if state.rollup != nil {
                    Button(state.showRawApps ? "Show categories" : "Show raw apps") {
                        state.showRawApps.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }

            if state.showRawApps {
                TodaySummaryView(summary: state.summary)
            } else if let cached = state.rollup {
                CategoryBarsView(
                    cached: cached,
                    totalActiveMs: state.summary.totalActiveMs
                )
            } else {
                // Default: v1 view until first categorization completes.
                TodaySummaryView(summary: state.summary)
                if let err = state.rollupError {
                    Text("Categorization: \(err)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
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

            // v2.0 — token management.
            Button(state.hasToken ? "Edit token…" : "Set token…") {
                state.editToken()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Reload token") {
                state.reloadToken()
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

            Button("Quit miniowl") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
