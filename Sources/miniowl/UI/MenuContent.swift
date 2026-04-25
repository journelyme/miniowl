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
            // Status = icon, not the word "Tracking" (which reads surveillance-y).
            // Paused = "pause.circle.fill", active = "circle.fill" in green.
            Image(systemName: state.paused ? "pause.circle.fill" : "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(state.paused ? Color.orange : Color.green)
                .accessibilityLabel(state.paused ? "Paused" : "Active")

            // Title doubles as a soft PR for the site. Every glance at the
            // menu bar is a nudge toward miniowl.me.
            Text("miniowl.me")
                .fontWeight(.semibold)

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
                } else if state.hasDeviceToken {
                    Text("Waiting for first categorization (every 20 min)…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRowButton(
                systemImage: state.paused ? "play.circle" : "pause.circle",
                title: state.paused ? "Resume tracking" : "Pause tracking",
                action: { state.togglePause() }
            )
            .keyboardShortcut("p")

            MenuRowButton(
                systemImage: "folder",
                title: "Open data folder",
                action: { state.openDataFolder() }
            )

            // (No manual "Categorize now" button — the product is "close
            // the menu, do your work, we'll tell you at the end of the
            // day". On-demand categorization invites attention drain and
            // pointless server load.)

            // Account connection via RFC 8628 device pairing flow.
            if state.isPairing {
                if let pairingState = state.pairingState {
                    pairingView(pairingState: pairingState)
                } else {
                    Text("Starting pairing…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            } else if state.hasDeviceToken {
                MenuRowButton(
                    systemImage: "rectangle.portrait.and.arrow.right",
                    title: "\(state.connectionStatus) · Sign out",
                    isLoading: state.isSigningOut,
                    action: { state.signOut() }
                )
            } else {
                MenuRowButton(
                    systemImage: "link.badge.plus",
                    title: state.isConnecting ? "Connecting…" : "Connect account…",
                    isLoading: state.isConnecting,
                    action: { state.connectAccount() }
                )
            }

            // Pairing error banner (remains after the row returns to the
            // "Connect account…" state so the user can see why it failed).
            if let error = state.pairingError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }

            MenuRowButton(
                systemImage: "square.and.pencil",
                title: "Edit context…",
                action: { state.editContext() }
            )

            if state.loginItemStatus != .enabled {
                MenuRowButton(
                    systemImage: "arrow.up.forward.app",
                    title: "Login items settings…",
                    action: { state.openLoginItemSettings() }
                )
            }

            Divider()
                .padding(.vertical, 4)

            MenuRowButton(
                systemImage: "power",
                title: "Quit Miniowl",
                action: { NSApp.terminate(nil) }
            )
            .keyboardShortcut("q")
        }
    }

    // MARK: - Pairing View

    private func pairingView(pairingState: PairingState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting to pair…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Code: \(pairingState.displayUserCode)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                if let url = URL(string: pairingState.verificationURL) {
                    Link("Open \(url.host ?? "verification page")", destination: url)
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    state.cancelPairing()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Spacer()

                if pairingState.isExpired {
                    Button("Try again") {
                        state.connectAccount()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Expires in \(Int(pairingState.expiresAt.timeIntervalSinceNow / 60))m")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
