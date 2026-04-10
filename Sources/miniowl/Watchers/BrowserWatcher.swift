import AppKit
import Foundation

/// Reads the URL of the active tab from a whitelisted browser via
/// AppleScript. Returns nil for any browser that isn't whitelisted, or
/// if the AppleScript call fails (permission denied, no open window,
/// browser unresponsive, etc.).
///
/// Scripts are **compiled once** at init and cached; each call reuses
/// the compiled `NSAppleScript` object so we pay the parse cost exactly
/// once per lifetime.
///
/// **Privacy:** AppleScript is a consent-based channel — each browser
/// voluntarily exposes a URL getter and macOS shows an Automation prompt
/// the first time we call it. We never read page content, cookies,
/// form data, browsing history, or tabs other than the frontmost one.
/// If the user declines the Automation prompt for a browser, that
/// browser is marked "unavailable" for the remainder of the session
/// and won't be prompted again until miniowl restarts.
final class BrowserWatcher {
    /// Bundle IDs of browsers we know how to query, mapped to the
    /// AppleScript source that returns the current tab URL.
    private static let scriptSources: [String: String] = [
        "com.google.Chrome": """
            tell application "Google Chrome"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
        """,
        "com.apple.Safari": """
            tell application "Safari"
                if (count of documents) = 0 then return ""
                return URL of current tab of front window
            end tell
        """,
        "company.thebrowser.Browser": """
            tell application "Arc"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
        """,
        "com.brave.Browser": """
            tell application "Brave Browser"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
        """,
    ]

    private var compiled: [String: NSAppleScript] = [:]
    private var unavailable: Set<String> = []  // bundle IDs we've given up on
    private let lock = NSLock()

    init() {
        for (bundleID, src) in Self.scriptSources {
            if let script = NSAppleScript(source: src) {
                var err: NSDictionary?
                script.compileAndReturnError(&err)
                if err == nil {
                    compiled[bundleID] = script
                }
            }
        }
    }

    /// Returns the active tab URL for the given bundle ID, or nil if
    /// the bundle isn't a whitelisted browser, isn't reachable, or the
    /// AppleScript call failed.
    ///
    /// Safe to call from any thread — protected by an internal lock
    /// because `NSAppleScript.executeAndReturnError` is not documented
    /// as thread-safe.
    func url(for bundleID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !unavailable.contains(bundleID),
              let script = compiled[bundleID]
        else {
            return nil
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let err = error {
            // Any error at all — permission denied, app not running,
            // compile failure — mark unavailable for this session.
            // Check if this looks like a TCC denial so we can log it
            // once with a helpful message.
            let errNum = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if errNum == -1743 || errNum == -600 {
                print("miniowl: automation denied for \(bundleID); URL tracking disabled until restart")
            }
            unavailable.insert(bundleID)
            return nil
        }

        guard let str = result.stringValue, !str.isEmpty else {
            return nil
        }
        return str
    }
}
