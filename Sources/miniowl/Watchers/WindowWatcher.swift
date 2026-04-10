import AppKit
import ApplicationServices
import Foundation

/// Watches the frontmost application and its focused-window title, and
/// (for whitelisted browsers) its active tab URL.
///
/// Two signal sources:
///   1. **Event-driven** — `NSWorkspace.didActivateApplicationNotification`
///      fires the instant you switch apps.
///   2. **Polling** — a 5s timer catches same-app title changes
///      (e.g. switching files within IntelliJ, tabs within a browser).
///
/// All Accessibility + AppleScript calls happen on a dedicated
/// background queue with a 0.5 s AX messaging timeout so an
/// unresponsive app can never hang the process.
///
/// Privacy: this class reads only the frontmost application's metadata,
/// the title of its focused window (via the Accessibility API), and —
/// for browsers on the BrowserWatcher whitelist — the current tab URL.
/// It NEVER reads child UI elements, text fields, clipboard, screen
/// contents, or keystrokes.
final class WindowWatcher {
    private let coordinator: EventCoordinator
    private let browserWatcher: BrowserWatcher
    private let queue = DispatchQueue(label: "miniowl.watcher.window")
    private var timer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?

    init(coordinator: EventCoordinator, browserWatcher: BrowserWatcher) {
        self.coordinator = coordinator
        self.browserWatcher = browserWatcher
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.sample() }
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(1), repeating: .seconds(5))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        self.timer = t

        // Nudge once immediately so the first event lands without
        // waiting for the first timer tick.
        queue.async { [weak self] in self?.sample() }
    }

    // MARK: - Sampling

    private func sample() {
        guard AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let bundleID = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? bundleID
        let title = windowTitle(for: app.processIdentifier)
        let url = browserWatcher.url(for: bundleID)  // nil for non-browsers
        let ts = nowMs()

        let kind = EventKind.window(
            bundleID: bundleID,
            appName: appName,
            title: title,
            url: url
        )
        Task { await coordinator.observe(kind, at: ts) }
    }

    /// Returns the focused window's title for the given process, or nil
    /// if AX is unresponsive, the app has no window, the title is empty
    /// (secure-input fields, 1Password, Terminal sudo), or the attribute
    /// isn't exposed.
    private func windowTitle(for pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var focused: CFTypeRef?
        let err1 = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focused
        )
        guard err1 == .success, let focusedWindow = focused else { return nil }

        let axWindow = focusedWindow as! AXUIElement
        var titleRef: CFTypeRef?
        let err2 = AXUIElementCopyAttributeValue(
            axWindow,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        guard err2 == .success, let s = titleRef as? String, !s.isEmpty else {
            return nil
        }
        return s
    }

    deinit {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        timer?.cancel()
    }
}
