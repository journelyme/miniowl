import Foundation

/// File-backed store for the categorization API token.
///
/// Phase 2a: plain text file at `~/Library/Application Support/miniowl/token.txt`.
/// Phase 2b: will migrate to macOS Keychain with user-supplied token from
/// a web signup flow.
///
/// Rationale for plain file over Keychain right now:
///   - User can edit it in a text editor (the "Edit token" button in the
///     menu opens it directly).
///   - Zero-UX Phase 2a flow: user drags a token file into the data dir,
///     restarts the app, done.
///   - File is under the user's home dir, same permissions as the
///     on-disk activity log. Not more exposed than what we already store.
///
/// The file should contain JUST the token string. Surrounding whitespace
/// (newlines, trailing spaces) is trimmed on read. An empty file means
/// "categorization disabled — fall back to v1."
struct TokenStore {
    let dataDir: URL

    var fileURL: URL {
        dataDir.appendingPathComponent("token.txt")
    }

    /// Read the token from disk. Returns nil if the file is missing,
    /// unreadable, or contains only whitespace.
    func read() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Create a placeholder token file with helpful instructions if one
    /// doesn't exist yet. Called on first launch so the user can find
    /// the file to edit.
    func initializeIfMissing() {
        if FileManager.default.fileExists(atPath: fileURL.path) { return }

        let placeholder = """
        # Paste your miniowl categorization token below this header.
        # Everything on lines starting with `#` is ignored.
        # Empty file = categorization disabled, v1 raw-app view only.
        #
        # In Phase 2a (testing), Trung shares a token directly.
        # In Phase 2b, you'll generate one on the miniowl web signup page.
        """
        try? placeholder.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Open the file in the user's default text editor. The "Edit token"
    /// menu button calls this — same interaction pattern the user
    /// requested.
    func openInEditor() {
        // Ensure the file exists so `open` actually opens something.
        initializeIfMissing()

        // `open -t` forces the user's default text editor (vs the app
        // that owns the .txt extension, which might be TextEdit OR
        // Xcode or VS Code depending on the last choice).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-t", fileURL.path]
        try? task.run()
    }

    /// Same as `read()`, but also strips lines starting with `#`. Used
    /// by the resolver so the placeholder commentary doesn't contaminate
    /// the token value.
    func readStripComments() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let lines = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let joined = lines.joined()
        return joined.isEmpty ? nil : joined
    }
}
