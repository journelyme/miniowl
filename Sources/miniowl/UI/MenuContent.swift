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
            Text("Today")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TodaySummaryView(summary: state.summary)
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
