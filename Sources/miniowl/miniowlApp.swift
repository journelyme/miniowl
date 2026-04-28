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
            // The label closure runs once when the Scene is built and
            // doesn't re-evaluate on its own. To make the menu-bar icon
            // swap when `paused` flips, the label has to be a real View
            // that observes AppState — that's what MenuBarLabel does.
            MenuBarLabel(state: appDelegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar icon view. ObservedObject on AppState makes SwiftUI re-render
/// this every time `state.paused` (or any other published property we
/// touch here) changes, swapping the icon between active and paused.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Custom owl icon rendered as template so macOS adapts color to
        // the menu bar appearance (dark bar → white icon, light bar →
        // dark icon) automatically.
        let iconName = state.paused ? "MenuBarIcon-paused" : "MenuBarIcon"
        if let img = loadMenuBarIcon(named: iconName) {
            Image(nsImage: img)
        } else {
            // Fallback to SF Symbol if the bundled PNG is missing
            // (e.g. during `swift run` without a full .app bundle).
            Image(systemName: state.paused ? "eye.slash" : "eye")
        }
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
