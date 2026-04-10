import AppKit
import SwiftUI

// ──────────────────────────────────────────────────────────────────────
// miniowl — main entry point (SwiftUI @main)
//
// A privacy-respecting, local-only macOS activity tracker. Lives in the
// menu bar (LSUIElement=true → no dock icon), writes JSONL to
// ~/Library/Application Support/miniowl/, and never touches the network.
//
// See README.md for the privacy contract + data format, and
// ~/.claude/plans/breezy-whistling-harp.md for the full design.
// ──────────────────────────────────────────────────────────────────────

@main
struct MiniowlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appDelegate.state)
        } label: {
            // Rendered in the menu bar. Template-rendered so it adapts
            // to the user's light/dark appearance automatically.
            Image(systemName: appDelegate.state.paused ? "eye.slash" : "eye")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

/// Hosts the AppState (so it survives across SwiftUI scene re-evaluations),
/// handles launch/terminate hooks, and installs SIGTERM/SIGINT traps so
/// `kill <pid>` still gives the coordinator a chance to flush.
///
/// @MainActor so `let state = AppState()` can call AppState's
/// MainActor-isolated initializer during property init.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state.start()
        installSignalHandler(SIGTERM)
        installSignalHandler(SIGINT)
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    private func installSignalHandler(_ sig: Int32) {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        signalSources.append(src)
    }
}
