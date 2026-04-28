// ─────────────────────────────────────────────────────────────────────
//  SyncCoordinator.swift
//
//  Outbox coordinator for /categorize calls.
//
//  Model:
//    - Each 20-min tick produces ONE pending window in sync_state.json.
//    - On every tick we (a) enqueue the new window and (b) drain up to
//      `maxDrainPerTick` oldest pending windows, sending each through
//      CategorizationClient.
//    - On success → mark synced, append response to CategorizationLog.
//    - On failure (network, server 5xx, timeout) → bump attempts, keep
//      pending, stop the drain (don't hammer a struggling backend).
//    - Stale entries (>24h or from a previous local day) are dropped on
//      access — events.mow files for past days aren't reliable to read
//      from the current process and stale windows have low signal anyway.
//
//  Server-side idempotency (migration 035 + Go check) means re-sending
//  a window whose row was already persisted is a safe no-op.
//
//  This actor serializes all access — there is no second writer, so
//  in-memory `entries` and on-disk `sync_state.json` stay in sync.
// ─────────────────────────────────────────────────────────────────────

import Foundation

/// Outcome the caller (AppState) cares about per tick.
struct SyncTickOutcome {
    /// Latest successfully-synced response (newest first), if any drained
    /// successfully this tick. AppState uses this to refresh its rollup +
    /// dayCategorization state.
    let latestSynced: CachedRollup?
    /// Last sync error for the menu's status line (nil = drained cleanly).
    let lastError: CategorizationError?
    /// Current outbox depth after the tick — surfaces in diagnostics.
    let pendingCount: Int
}

actor SyncCoordinator {
    // ─── Caps ────────────────────────────────────────────────────────
    /// Outbox depth ceiling. If we'd exceed it, the oldest pending entry
    /// is dropped. Practical bound: ~33 hours of windows at 3/hr.
    private let maxQueueDepth = 100
    /// Age cap. Anything older than this on access is dropped.
    private let staleTTL: TimeInterval = 24 * 3600
    /// Per-tick drain ceiling. Matches the gateway's 5/min rate limit on
    /// /pair/start; /categorize is 10/min, so 5 leaves headroom for the
    /// new live-window send + 4 catch-ups without bursting.
    private let maxDrainPerTick = 5

    // ─── Deps ────────────────────────────────────────────────────────
    private let syncState: SyncState
    private let dataDir: URL

    // ─── In-memory mirror of sync_state.json ─────────────────────────
    private var entries: [SyncEntry]

    init(syncState: SyncState, dataDir: URL) {
        self.syncState = syncState
        self.dataDir = dataDir
        self.entries = syncState.load()
    }

    // MARK: - Public API

    /// Add a new window to the outbox. Idempotent on `endMs` — if a
    /// window with the same end time is already tracked (any status),
    /// this is a no-op.
    ///
    /// Caller is expected to invoke `drain(...)` after enqueue to
    /// actually send pending entries.
    func enqueue(startMs: Int64, endMs: Int64, tz: String) {
        prune(now: Date())

        if entries.contains(where: { $0.endMs == endMs }) {
            return // already tracked
        }

        let entry = SyncEntry(
            startMs: startMs,
            endMs: endMs,
            tz: tz,
            enqueuedAtMs: nowMs(),
            status: .pending,
            attempts: 0,
            lastAttemptAtMs: nil,
            syncedAtMs: nil
        )
        entries.append(entry)

        // If we'd exceed the depth cap, evict the oldest pending. Synced
        // entries are pruned separately (see pruneSynced) so they don't
        // count against live outbox capacity.
        let pending = entries.filter { $0.status == .pending }
        if pending.count > maxQueueDepth {
            if let idx = entries.firstIndex(where: { $0.status == .pending }) {
                entries.remove(at: idx)
            }
        }

        persist()
    }

    /// Drain up to `maxDrainPerTick` oldest pending windows, oldest first.
    ///
    /// On each successful POST: marks the entry synced, appends the
    /// response to CategorizationLog, recomputes day totals.
    /// On the first failure: stops the drain and reports the error.
    func drain(
        client: CategorizationClient,
        log: CategorizationLog,
        currentDayData: DayCategorization?
    ) async -> SyncTickOutcome {
        let now = Date()
        prune(now: now)

        let todayLocal = DateUtils.localDateString(for: now)

        // Pick oldest-first pending entries that belong to today.
        let pendingToday = entries.enumerated()
            .filter { _, e in
                guard e.status == .pending else { return false }
                let entryDate = DateUtils.localDateString(
                    for: Date(timeIntervalSince1970: TimeInterval(e.endMs) / 1000)
                )
                return entryDate == todayLocal
            }
            .sorted { $0.element.endMs < $1.element.endMs }
            .prefix(maxDrainPerTick)

        var latestSynced: CachedRollup?
        var lastError: CategorizationError?

        for (idx, entry) in pendingToday {
            do {
                let cached = try await sendOne(
                    entry: entry,
                    client: client,
                    log: log,
                    currentDayData: currentDayData
                )
                // Mark synced in place. (idx is stable because we only
                // mutate this single element here.)
                var updated = entries[idx]
                updated.status = .synced
                updated.syncedAtMs = nowMs()
                entries[idx] = updated
                persist()

                latestSynced = cached
            } catch let err as CategorizationError {
                // Bump attempts, leave pending. Stop draining further so
                // we don't hammer a struggling backend.
                var updated = entries[idx]
                updated.attempts += 1
                updated.lastAttemptAtMs = nowMs()
                entries[idx] = updated
                persist()

                lastError = err
                break
            } catch {
                // Unexpected non-CategorizationError — same handling.
                var updated = entries[idx]
                updated.attempts += 1
                updated.lastAttemptAtMs = nowMs()
                entries[idx] = updated
                persist()

                lastError = .transport(error)
                break
            }
        }

        return SyncTickOutcome(
            latestSynced: latestSynced,
            lastError: lastError,
            pendingCount: entries.filter { $0.status == .pending }.count
        )
    }

    /// Diagnostic — used by tests and (possibly later) the menu.
    func snapshot() -> [SyncEntry] {
        return entries
    }

    /// Wipe — called on Sign out so a fresh pairing doesn't replay an
    /// orphaned previous-account outbox into the new account.
    func reset() {
        entries = []
        syncState.clear()
    }

    // MARK: - Internals

    /// Send one pending entry. Reconstructs the request from today's
    /// .mow events file and POSTs it. Returns the cached rollup on
    /// success; throws on any error (caller decides what to do).
    private func sendOne(
        entry: SyncEntry,
        client: CategorizationClient,
        log: CategorizationLog,
        currentDayData: DayCategorization?
    ) async throws -> CachedRollup {
        let endDate = Date(timeIntervalSince1970: TimeInterval(entry.endMs) / 1000)
        let localDate = DateUtils.localDateString(for: endDate)
        let file = dataDir.appendingPathComponent("\(localDate).mow")

        // Window length in seconds. buildRequest computes
        // windowStart = now - window, so we set now = endDate and
        // window = (end - start) / 1000 to recover the original window.
        let windowSeconds = TimeInterval(entry.endMs - entry.startMs) / 1000

        guard let req = CategoryRollup.buildRequest(
            file: file,
            window: windowSeconds,
            now: endDate,
            timezone: TimeZone(identifier: entry.tz) ?? .current,
            dayCategorization: currentDayData
        ) else {
            // No events in the requested window — treat as a benign
            // "nothing to send", but still mark the entry "synced" so we
            // don't keep retrying. We synthesize an empty success response
            // so the UI doesn't get a misleading error.
            throw CategorizationError.notConfigured
        }

        let resp = try await client.categorize(req)
        let cached = CachedRollup(response: resp, computedAt: Date())

        do {
            try log.append(cached, request: req)
        } catch {
            fputs("miniowl: categorization log append failed: \(error)\n", stderr)
        }

        return cached
    }

    /// Drop entries that are stale (>24h enqueued) OR fully synced rows
    /// from previous days. Kept simple — no cross-day replay.
    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 * 1000 - staleTTL * 1000
        let todayLocal = DateUtils.localDateString(for: now)

        let before = entries.count
        entries.removeAll { entry in
            // Stale by age
            if Double(entry.enqueuedAtMs) < cutoff { return true }

            // Synced + from a previous local day → no longer needed
            if entry.status == .synced {
                let entryDate = DateUtils.localDateString(
                    for: Date(timeIntervalSince1970: TimeInterval(entry.endMs) / 1000)
                )
                if entryDate != todayLocal { return true }
            }
            return false
        }

        if entries.count != before {
            persist()
        }
    }

    private func persist() {
        do {
            try syncState.save(entries)
        } catch {
            // Log and keep going — losing the file means we'll re-enqueue
            // on next tick (idempotency at the server prevents double-count).
            fputs("miniowl: sync_state save failed: \(error)\n", stderr)
        }
    }

    private func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
