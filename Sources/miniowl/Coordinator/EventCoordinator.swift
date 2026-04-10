import Foundation

/// Single-writer actor that turns raw watcher observations into merged
/// events and appends them to the on-disk log.
///
/// All file writes funnel through here, so there are no races on the
/// EventLog's FileHandle. Watchers are "dumb producers" — they tell the
/// coordinator what they just saw, and the coordinator decides whether
/// to extend the pending event in memory or close it and open a new one.
///
/// Additional responsibilities added in M4–M7:
///   - **Heartbeat** (`heartbeat()`): refreshes the pending event's end
///     timestamp and persists it to `state.json` so a crash loses at
///     most the heartbeat interval worth of data.
///   - **Rotation** (`rotateIfNeeded()`): if the local date has ticked
///     over, flush the current pending, gzip yesterday's file, and
///     open today's.
///   - **Pause** (`setPaused(_:)`): drops incoming observations and
///     emits `paused` / `resumed` system markers for honest gap data.
actor EventCoordinator {
    private let log: EventLog
    private let stateFile: StateFile
    private var pending: PendingEvent?
    private var paused = false

    init(log: EventLog, stateFile: StateFile) {
        self.log = log
        self.stateFile = stateFile

        // Crash recovery: if the previous session left a pending
        // snapshot, append it to the log as a finished event so we
        // don't lose up to `heartbeatInterval` seconds of tracked time.
        //
        // Simplification: we always append into whatever file is
        // currently today's. If the previous session spanned midnight,
        // the recovered event ends up in today's file with timestamps
        // from yesterday. Downstream queries handle that fine (group by
        // timestamp, not filename).
        if let pendingLine = stateFile.readPendingLine() {
            do {
                try log.append(line: pendingLine)
                print("miniowl: recovered pending event from previous session")
            } catch {
                fputs("miniowl: state recovery write failed: \(error)\n", stderr)
            }
            stateFile.clear()
        }
    }

    // MARK: - Ingest

    /// Record an interval-kind observation. If the new observation
    /// matches the pending event, we just extend `endMs` in memory —
    /// no disk write. Otherwise, we flush the previous pending event
    /// to disk and open a new one (and refresh state.json).
    func observe(_ kind: EventKind, at timestamp: Int64) {
        if paused { return }

        if var p = pending, p.canExtend(with: kind) {
            p.endMs = timestamp
            pending = p
            // No state file update on extend — heartbeat handles it
            // every 10s. Avoids a disk write per sample.
            return
        }
        if let p = pending {
            writeClosedEvent(p)
        }
        pending = PendingEvent(kind: kind, startMs: timestamp, endMs: timestamp)
        persistPending()
    }

    /// Record a point-in-time system event. This closes the pending
    /// interval event first so the on-disk order is correct.
    ///
    /// System events are never dropped by pause — `sleep`, `wake`,
    /// and `lock` remain useful for reconstructing your day even when
    /// tracking is paused.
    func systemEvent(kind: String, at timestamp: Int64 = nowMs()) {
        if let p = pending {
            writeClosedEvent(p)
            pending = nil
            stateFile.clear()
        }
        let obj: [String: Any] = [
            "t": "s",
            "s": timestamp,
            "k": kind,
        ]
        writeJSON(obj)
    }

    /// Force the pending event to close and flush to disk. Called on
    /// sleep, quit, and rotation so nothing straddles the boundary.
    func flush(at timestamp: Int64 = nowMs()) {
        guard var p = pending else {
            stateFile.clear()
            return
        }
        p.endMs = timestamp
        writeClosedEvent(p)
        pending = nil
        stateFile.clear()
    }

    // MARK: - Pause / Resume (M7)

    func setPaused(_ newValue: Bool) {
        guard newValue != paused else { return }
        if newValue {
            // Entering pause: close pending, then mark.
            if let p = pending {
                writeClosedEvent(p)
                pending = nil
                stateFile.clear()
            }
            paused = true
            writeJSON(["t": "s", "s": nowMs(), "k": "paused"])
        } else {
            paused = false
            writeJSON(["t": "s", "s": nowMs(), "k": "resumed"])
        }
    }

    // MARK: - Heartbeat (M5)

    /// Refresh the pending event's end timestamp and persist a snapshot
    /// to `state.json`. Called by AppState's 10 s timer.
    func heartbeat() {
        guard var p = pending else { return }
        p.endMs = nowMs()
        pending = p
        persistPending()
    }

    // MARK: - Rotation (M4)

    /// Check whether the local date has changed; if so, flush pending,
    /// rotate the event log (gzip yesterday, open today), and clear
    /// state.json. Called by AppState's 60 s timer.
    func rotateIfNeeded() {
        guard let newDate = log.checkRotation() else { return }

        if let p = pending {
            writeClosedEvent(p)
            pending = nil
        }
        stateFile.clear()

        do {
            try log.rotate(toNewDate: newDate)
            print("miniowl: rotated to \(newDate)")
        } catch {
            fputs("miniowl: rotation failed: \(error)\n", stderr)
        }
    }

    // MARK: - Writing

    private func writeClosedEvent(_ p: PendingEvent) {
        guard let data = Self.encodeInterval(p) else { return }
        do {
            try log.append(line: data)
        } catch {
            fputs("miniowl: failed to append event: \(error)\n", stderr)
        }
    }

    /// Persist the current pending event to state.json so a crash can
    /// recover it. Caller must ensure `pending` is non-nil when this
    /// path is expected to write; nil clears the state file.
    private func persistPending() {
        guard let p = pending, let data = Self.encodeInterval(p) else {
            stateFile.clear()
            return
        }
        do {
            try stateFile.persist(pendingLine: data)
        } catch {
            fputs("miniowl: state persist failed: \(error)\n", stderr)
        }
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            fputs("miniowl: failed to encode event\n", stderr)
            return
        }
        do {
            try log.append(line: data)
        } catch {
            fputs("miniowl: failed to append event: \(error)\n", stderr)
        }
    }

    /// Single encoder for interval events — used for both "closed to
    /// disk" and "snapshot to state.json" so the two can't drift.
    ///
    /// Returns nil for `afk(away: false)` so that "active" intervals
    /// are silently dropped (active is implied as the complement).
    private static func encodeInterval(_ p: PendingEvent) -> Data? {
        var obj: [String: Any] = [:]
        switch p.kind {
        case let .window(bundleID, appName, title, url):
            obj = [
                "t": "w",
                "s": p.startMs,
                "e": p.endMs,
                "b": bundleID,
                "n": appName,
                "ti": title ?? NSNull(),
                "u": url ?? NSNull(),
            ]
        case let .afk(away):
            guard away else { return nil }
            obj = [
                "t": "a",
                "s": p.startMs,
                "e": p.endMs,
                "k": 1,
            ]
        }
        return try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
