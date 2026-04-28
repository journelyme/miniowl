// ─────────────────────────────────────────────────────────────────────
//  SyncState.swift
//
//  Outbox-pattern persistence for categorize windows. Lives in
//  `~/Library/Application Support/miniowl/sync_state.json` and tracks
//  which 20-min windows have been confirmed-persisted on the server vs
//  still pending retry.
//
//  Why a separate file (not state.json):
//    state.json is owned by EventCoordinator for crash-recovery of the
//    currently-open event. It writes on every heartbeat (every few
//    seconds). Keeping outbox state in its own file avoids contention
//    and accidental corruption from one writer stomping the other.
//
//  Privacy: this file stores ONLY window timing + sync metadata. No
//  events, no titles, no URLs. Replay reconstructs the request by
//  scanning the existing per-day .mow event log.
//
//  Atomicity: writes go to a `.tmp` file then atomically rename, so a
//  crash mid-write can't leave a half-written sync_state.json.
//
//  Caps (enforced by SyncCoordinator, not here):
//    - max 100 windows tracked
//    - 24h stale TTL
//    - drain ≤5 pending per tick
// ─────────────────────────────────────────────────────────────────────

import Foundation

/// Lifecycle status of a window in the outbox.
enum SyncStatus: String, Codable {
    /// Enqueued, not yet successfully delivered to the server.
    case pending
    /// Server confirmed persistence. Kept in the file briefly so the
    /// UI can prove "today's totals" match the server. Pruned at end
    /// of day or when count cap is reached.
    case synced
}

/// One entry in the outbox. Window timing is in Unix milliseconds (UTC)
/// to match the wire format the categorize endpoint expects.
struct SyncEntry: Codable, Equatable {
    /// Unix-ms (UTC) of the window's start.
    let startMs: Int64
    /// Unix-ms (UTC) of the window's end. Used as the idempotency anchor.
    let endMs: Int64
    /// IANA timezone id active when the window was captured.
    let tz: String
    /// When this entry was first added to the outbox (Unix-ms UTC).
    let enqueuedAtMs: Int64
    var status: SyncStatus
    /// Total send attempts so far (incremented on every failed POST).
    var attempts: Int
    /// Most recent attempt timestamp, Unix-ms UTC. Nil until first try.
    var lastAttemptAtMs: Int64?
    /// Set when status flips to .synced. Unix-ms UTC.
    var syncedAtMs: Int64?
}

/// On-disk envelope. Versioned so we can evolve the schema without
/// breaking forward-compat reads.
private struct SyncEnvelope: Codable {
    let v: Int
    var windows: [SyncEntry]
}

/// File-backed sync state. NOT thread-safe — funnel access through
/// SyncCoordinator (an actor).
final class SyncState {
    private let url: URL

    init(directory: URL) {
        self.url = directory.appendingPathComponent("sync_state.json")
    }

    // MARK: - Disk I/O

    /// Read the current envelope. Returns an empty list on missing /
    /// corrupt file (we'd rather start fresh than crash on a bad state).
    func load() -> [SyncEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let env = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
            // Corrupt file — log via stderr, drop and rebuild. We don't
            // crash the app over a malformed cache file.
            fputs("miniowl: sync_state.json malformed, ignoring\n", stderr)
            return []
        }
        return env.windows
    }

    /// Atomically replace the envelope.
    func save(_ entries: [SyncEntry]) throws {
        let env = SyncEnvelope(v: 1, windows: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(env)

        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Wipe — used by tests and `Sign out` to reset the outbox.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
