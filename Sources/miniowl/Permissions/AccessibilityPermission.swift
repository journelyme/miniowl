import AppKit
import ApplicationServices

/// Thin wrapper around the Accessibility TCC status check + a helper
/// that opens the right pane of System Settings for the user to toggle.
enum AccessibilityPermission {
    /// `AXIsProcessTrusted()` — returns true if the current process has
    /// been granted Accessibility permission in System Settings.
    static var isGranted: Bool {
        return AXIsProcessTrusted()
    }

    /// Opens System Settings → Privacy & Security → Accessibility so
    /// the user can find the toggle for miniowl without hunting.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
