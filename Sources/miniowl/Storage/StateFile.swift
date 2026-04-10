import Foundation

/// Persists the currently-open "pending" event to a small JSON file so
/// that a crash or kill -9 can only lose at most `heartbeatInterval`
/// seconds of tracked time. See EventCoordinator.heartbeat.
///
/// On disk:
/// ```
/// {
///   "v": 1,
///   "updated": 1712739720000,
///   "pending": {"t":"w","s":...,"e":...,"b":"...","n":"...","ti":"...","u":null}
/// }
/// ```
///
/// Writes are atomic (write to temp + rename) so a power loss mid-write
/// cannot leave a truncated file.
///
/// NOT thread-safe. Access funnels through the EventCoordinator actor.
final class StateFile {
    private let url: URL

    init(directory: URL) {
        self.url = directory.appendingPathComponent("state.json")
    }

    /// Write the pending snapshot atomically. The caller passes the raw
    /// JSON bytes for the pending event (same format as a `.mow` line);
    /// we wrap those bytes in an envelope and persist.
    func persist(pendingLine: Data) throws {
        guard let pendingObj = try? JSONSerialization.jsonObject(with: pendingLine)
                as? [String: Any]
        else {
            throw StateFileError.badPendingJSON
        }
        let envelope: [String: Any] = [
            "v": 1,
            "updated": nowMs(),
            "pending": pendingObj,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        // Atomic write: tmp → rename.
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Remove the state file. Called on graceful flush, pause, and
    /// successful recovery.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// If a prior session left a pending snapshot, return its raw JSON
    /// bytes (ready to append to the event log as a single line).
    /// Returns nil if the file is missing, malformed, or has no pending.
    func readPendingLine() -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        guard let pending = obj["pending"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: pending,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

enum StateFileError: Error {
    case badPendingJSON
}
