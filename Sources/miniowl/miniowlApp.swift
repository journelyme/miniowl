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
            // Custom owl icon rendered as template so macOS adapts the
            // color to the menu bar appearance (dark bar → white icon,
            // light bar → dark icon) automatically.
            let iconName = appDelegate.state.paused ? "MenuBarIcon-paused" : "MenuBarIcon"
            if let img = loadMenuBarIcon(named: iconName) {
                Image(nsImage: img)
            } else {
                // Fallback to SF Symbol if bundled icon is missing
                // (e.g. during `swift run` without a full .app bundle).
                Image(systemName: appDelegate.state.paused ? "eye.slash" : "eye")
            }
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

// MARK: - Menu bar icon loader

/// Load a PNG from the app bundle's Resources directory and configure it
/// as a template image (single-color, macOS adapts to light/dark bar).
/// Size is set to 18×18 pt so it matches standard menu bar icon dimensions.
func loadMenuBarIcon(named name: String) -> NSImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let img = NSImage(contentsOf: url) else {
        return nil
    }
    img.isTemplate = true
    img.size = NSSize(width: 18, height: 18)
    return img
}
